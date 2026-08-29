// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ArbiterAccountabilityFacet.sol
//
// Accountability for manually curated arbiters: suspension, removal for cause,
// the chief arbiter's proposal, and the ACCUSED party's right of reply — since
// 19 August 2026 the reply is accepted while the pause is still running, not
// only after the removal.
//
// WHY A SEPARATE FACET rather than more code inside ArbiterRegistryFacet: that
// one is out of room, and it has grown tighter since. A snapshot that goes
// stale with every edit to the registry: 21 227 bytes of 24 576 (86.4 %) on
// 15 August 2026 → 23 072 of 24 576 (93.9 %, 1 504 to spare) on 19 August. The
// current number comes from `forge build --sizes`, not from here; the standing
// consequence is that a new function belongs HERE by default, not in the
// registry. Diamond facets share storage by namespace, so this one works
// against the same ArbiterRegistryStorage and the same POSITION — no data is
// moved at all.
//
// Suspension came first (15 August 2026) — fast, reversible, expiring by
// itself. Removal for cause (removeArbiterForCause) followed the same day: the
// bare removeArbiter in ArbiterRegistryFacet was dropped entirely, because it
// recorded neither who pressed the button nor why, and returned the bond in
// full — a removal for cause and a quiet purge looked identical on chain and
// cost the same. Then came the chief arbiter's proposal
// (proposeRemoval/withdrawProposal): removal is irreversible and stays the
// owner's right (or daoAddress once transferred), while the chief lays down his
// own SIGNALLING record under a separate address — the feed shows both who
// proposed and who agreed, instead of one record standing in for two people.
//
// ⚠️ respondToRemoval is the FIRST and ONLY gasless function of this facet. It
// is called by the accused or removed arbiter — an ordinary person who may hold
// no ETH (since 19 August 2026 the reply is accepted DURING the pause too, so
// the caller here is most often a serving arbiter under a live accusation); on
// the path through the relayer msg.sender is the MinimalForwarder address, not
// the person. The file therefore implements its own _msgSender() (a copy of the
// body of ArbiterRegistryFacet._msgSender — for what that coincidence is and is
// NOT guarded by, see the docstring of the function itself below) and became an
// ERC-2771 file: the build gate that rejects a raw msg.sender in gasless
// contracts discovers it on its own, and its list of documented exceptions
// accounts for the file per-function, like the neighbouring
// ArbiterRegistryFacet/JobBoardFacet/ServiceBoardFacet, rather than through
// one blanket "out of scope" entry.
//
// EVERY OTHER function of the facet stays administrative (the owner, or the
// chief arbiter until the DAO is active) and still reads the raw msg.sender —
// a gasless path is not needed there and would be dangerous: trusting the tail
// of calldata inside an ownership check hands that check to the forwarder. The
// reasons are listed function by function in the build gate's list of
// documented exceptions.
// ============================================================

// ArbiterRegistryFacet itself, not only its storage library: this facet now
// emits ArbiterDemoted and speaks DemotionPath, both declared there. One
// declaration, one topic0 — a copy of the event here would compile, produce
// an identical log and drift the first time either side is edited.
import {ArbiterRegistryStorage, ArbiterRegistryFacet} from "./ArbiterRegistryFacet.sol";
import {ReputationStorage} from "./ReputationFacet.sol";
import {OwnershipLib} from "../DiamondProxy.sol";
import {FactoryStorage} from "../FactoryFacet.sol";

contract ArbiterAccountabilityFacet {

    // -------- CONSTANTS --------

    // The suspension window (SUSPENSION_WINDOW, 72 hours) moved into
    // ArbiterRegistryStorage on 16 August 2026. The reason sits next to the
    // declaration there: the suspension is set by TWO doors in TWO files
    // (removeArbiterForCause here and the automatic demotion in
    // ArbiterRegistryFacet._recordArbiterMistake), and a copy of the number in
    // the second one would be the same class of defect as the duplicated
    // constant already removed from this pair — two literals that drift apart
    // silently. The value did not change; getSuspensionWindow() below still
    // returns it.

    /// Mirror of MAX_ARBITER_MISTAKES from ArbiterRegistryFacet — not itself the
    /// removal threshold, but the anchor from which MISTAKE_THRESHOLD below is
    /// derived by subtraction. Agreement with the original is checked by the
    /// test test_MistakeThresholdMatchesRegistry.
    uint256 private constant MAX_ARBITER_MISTAKES_MIRROR = 3;

    /// The threshold at which a HUMAN proves cause. Strictly below the automatic
    /// one (MAX_ARBITER_MISTAKES = 3), and that is the design: TWO mistakes in a
    /// row and the owner sees it and removes the arbiter personally, with the
    /// reason recorded on chain; on the THIRD the chain raises the accusation by
    /// itself. The manual path earns its place by firing EARLIER than the
    /// automaton, not by duplicating it.
    ///
    /// ⚠️ THE OLD RATIONALE FOR −1 NO LONGER HOLDS (18 August 2026). It used to
    /// be technical: "`_recordArbiterMistake`, on reaching MAX_ARBITER_MISTAKES
    /// in a single transaction, both clears `isArbiter` and zeroes the counter,
    /// so at rest `arbiterMistakeStreak` ∈ {0, …, MAX−1}, and a threshold on
    /// equality would be unreachable forever". Both halves died: the third
    /// mistake no longer removes, it accuses, and it does not zero the counter —
    /// at rest the value now reaches three as well.
    ///
    /// The rationale for −1 survives, but it is now about design rather than
    /// reachability: two thresholds standing for the same thing would be a door
    /// that adds nothing to the automatic path.
    ///
    /// ⚠️ WHAT THIS THRESHOLD DOES AND DOES NOT DO. It gates the MANUAL door and
    /// only it: `_requireProven` is called from `removeArbiterForCause` and from
    /// nowhere else. `executeChainRemoval` does not re-check cause at all — it
    /// asks for the record the chain laid down, and fires with the counter at 0
    /// by design.
    ///
    /// And the counter is not zeroed after the automatic path for a reason that
    /// has nothing to do with this button: a streak of judging mistakes did not
    /// end merely because the chain noticed it.
    ///
    /// The trap of an acquittal on appeal being outlived by the chain's own
    /// accusation is likewise not held by the arithmetic of these numbers: that
    /// record would survive an acquittal by the panel at ANY value of the
    /// counter — which is why `resolveAppeal` erases the record itself instead
    /// of adjusting a number.
    ///
    uint256 private constant MISTAKE_THRESHOLD = MAX_ARBITER_MISTAKES_MIRROR - 1;

    // The mirror of DEMOTION_XP_RESET (2500) was dropped on 16 August 2026. It
    // had been declared "an anchor for the future" and was read from nowhere: a
    // third copy of a number belonging to a neighbouring facet — and the only
    // one of the three without a getter and without a cross-check. The other two
    // mirrors in this file (MAX_ARBITER_MISTAKES_MIRROR, DAO_THRESHOLD_MIRROR)
    // are exposed through getters and checked against the live numbers by tests;
    // that one was checked by nothing and would have drifted silently. Should a
    // removal for cause ever need to reset XP, the number will come from
    // ArbiterRegistryFacet together with that decision, instead of lying here
    // for a year as a literal of its own.

    /// How long a chief arbiter's proposal lives (15 August 2026). Approved by
    /// the owner: long enough to come back from a holiday, short enough that an
    /// accusation does not hang around for a quarter.
    uint256 private constant PROPOSAL_TTL = 14 days;

    /// The ceiling on words, in BYTES rather than characters — the chain does
    /// not count characters and cannot: `bytes(s).length` is the UTF-8 length,
    /// and "256 characters" is 512 bytes in Cyrillic and 1024 in emoji.
    ///
    /// The number is chosen so that the ~256 characters promised by the owner
    /// fit in the WORST of the encodings people actually write in here: 512
    /// bytes is 512 Latin characters, or 256 Cyrillic ones. Enough for "took
    /// three disputes of one counterparty and ruled for him all three times"
    /// (123 bytes) and not enough to turn the chain into a blog.
    ///
    /// ⚠️ The form must show the remainder IN BYTES. A "40 characters left"
    /// counter lies by a factor of four on the first emoji, and the person gets
    /// a rejected transaction instead of a hint.
    uint256 private constant MAX_REASON_BYTES = 512;

    /// The pause between a proposal and the removal it authorises (design of
    /// 17 August 2026). The clock runs FROM THE PROPOSAL and the accused
    /// answering does not move it.
    ///
    /// The number is proportionate to its neighbours rather than picked out of
    /// thin air: suspension lasts 72 hours, the verdict finalisation window 24.
    /// One day for the person to notice at all, one day to answer. Under a day
    /// is missable by anyone who did not log in; over a week and the arbiter
    /// hangs while his disputes stand still.
    ///
    /// ⚠️ Rejected alternative: "silence buys a fast removal, an answer buys
    /// the full pause". It creates a perverse
    /// incentive — the silent get removed sooner, so answering pays as a way of
    /// stalling rather than because there is something to say. It also lets the
    /// button be pressed while the person sleeps.
    ///
    /// ⚠️ There is no fast path to removal and none may be added: "he is doing
    /// damage right now" is covered by suspendArbiter — instant, reversible,
    /// expiring by itself. Two levers of different speed, and that separation
    /// is half the design.
    uint256 private constant REMOVAL_DELAY = 48 hours;

    /// The stage at which the words were said. Travels as an indexed topic so
    /// that the feed can ask for "show all accusations" separately from "show
    /// all removals" without decoding the event body.
    uint8 private constant REASON_STAGE_PROPOSAL = 0;
    uint8 private constant REASON_STAGE_REMOVAL  = 1;

    // -------- ERRORS --------

    error NotOwnerOrChief();
    error NotOwner();
    error NotAnArbiter();
    error ArbiterZeroAddress();

    // ── Weight of a suspension (16 August 2026) ──
    /// A WEIGHTY suspension — one imposed by a removal, and since 18 August
    /// 2026 also by the CHAIN's own accusation for as long as it stands — is
    /// lifted only by the HOLDER OF THE REMOVAL RIGHT. The second half exists
    /// because the automatic path stopped removing outright: without it the
    /// chief arbiter could mute the fast lever in a single transaction, exactly
    /// the bypass this rule was written to close.
    /// A separate error rather than NotOwner: a chief arbiter who got NotOwner
    /// on a function that is generally allowed to him would go looking for the
    /// problem in his own role. The point here is not the role but the weight of
    /// this particular suspension.
    ///
    /// ⚠️ RENAMED. It used to be called `RemovalSuspensionIsOwnerOnly`, and once
    /// the removal right became transferable the name started lying: the right
    /// belongs not to the owner in general but to whoever holds removal TODAY
    /// (`_removalAuthority`) — the owner before the transfer, the named
    /// successor after it. An error name is not part of `methodIdentifiers`, so
    /// a rename does not change the composition of the cut — verified by
    /// comparing hashes of the selector maps of both facets before and after,
    /// not taken on trust.
    error RemovalSuspensionIsRemovalAuthorityOnly();

    // ── Removal for cause (15 August 2026) ──
    error CauseNotProven(uint8 cause);
    error EvidenceRequired();
    /// The removal right has moved to the named successor — only daoAddress may
    /// call (see removeArbiterForCause). The owner gets this same error: it is a
    /// hand-over, not a locking into the void, but the hand-over is one-way and
    /// there is no road back for the owner.
    ///
    /// ⚠️ Precisely "to the NAMED one" (16 August 2026): while `daoAddress` is
    /// zero this error is raised for nobody, however many paths may have turned
    /// `isDaoActive()` on — there is no one to hand over to, and the door stays
    /// with the owner.
    error RemovalHandedOver();
    error DisputeRefRequired();
    error DisputeRefNotApplicable();

    // ── The accused party's right of reply (15 August 2026; since 19 August the
    //    reply is accepted DURING the pause too, not only after a removal) ──
    error AlreadyAnswered();
    error NothingToAnswer();
    error ZeroDigest();

    // ── The reason in words (design of 17 August 2026) ──
    /// The chain does not verify this cause, so the accuser is obliged to
    /// explain in words. The obligation lies on the accuser and on him alone:
    /// for the accused, words are a right.
    error ReasonRequired();
    /// The length in BYTES, not in characters. The value comes back inside the
    /// error so that the form can show exactly how far over the limit it went.
    error ReasonTooLong(uint256 given);

    // ── The 48-hour pause (design of 17 August 2026) ──
    /// There is nothing to execute: no proposal stands against this address at
    /// all, or it was withdrawn. A separate error from ProposalStale — there
    /// the accusation existed and expired, here it never existed.
    error NoLiveProposal();
    /// The clock is still running. Carries THE MOMENT from which removal is
    /// allowed, so the form can say "19 hours to go" instead of "try later".
    error RemovalTooEarly(uint256 notBefore);
    /// The proposal outlived PROPOSAL_TTL. Executing it would mean an
    /// accusation half a year old firing without a fresh warning.
    error ProposalStale(uint256 proposedAt);
    /// Warned about one thing, removed for another. The pause exists so the
    /// person can answer THAT PARTICULAR accusation; swapping the code
    /// devalues both the pause and the answer.
    error CauseDiffersFromProposal(uint8 proposed, uint8 given);
    /// The caller is allowed on this door in general, but THIS proposal is not
    /// his. A separate error from NotOwnerOrChief on purpose: there the role is
    /// wrong, here the role is right and the record belongs to someone else.
    ///
    /// ⚠️ Introduced together with the pause (17 August 2026), and the pause is
    /// what made it necessary. Until then a withdrawal cancelled a
    /// SIGNAL — it took nothing away, because removal did not depend on the
    /// proposal at all. Now the proposal is a MANDATORY INPUT, so withdrawing
    /// someone else's is the power to stop a removal. The chief was
    /// deliberately denied the power to REMOVE; handing him the power to
    /// PREVENT a removal — and to do it again every time, proposal after
    /// proposal — is no lighter.
    error NotYourProposal();

    /// A live proposal occupies the door. Named fields, not a bare marker: the
    /// caller needs to know WHOSE record stands in the way and since when —
    /// without them the only recourse is to guess, and the front cannot tell
    /// "someone beat you to it" from "you already did this".
    error ProposalAlreadyLive(address by, uint256 proposedAt);

    /// executeChainRemoval was pressed against an accusation a PERSON laid.
    /// The button exists only for the chain's own (`by == address(0)`); a human
    /// accusation is executed by the holder of the removal right, through
    /// removeArbiterForCause, with his arguments and his name on it. Owner's
    /// condition, 18 August 2026: "the main thing is that overriding it must
    /// not fly".
    error NotAChainProposal();

    /// The mirror of the line above, and the pair only works with both halves
    /// (18 August 2026). removeArbiterForCause was
    /// executing accusations the CHAIN laid, because it read the record and
    /// never looked at `by` — measured on a live diamond, not suspected: the
    /// removal went through and the permanent record changed its ORIGIN, from
    /// 253 ("the chain, by overturns") to 1 ("a person, for cause"), with
    /// ArbiterRemovedForCause naming the owner where ArbiterDemoted would have
    /// named nobody. Two storage fields exist to keep that distinction —
    /// chainProposalPath and lastRemovalCause — and one call erased it.
    ///
    /// This is not a new rule, it is the one already settled by the design: the
    /// accuser here is the chain, and no person's name is attached to its
    /// accusation. Nothing is lost by refusing —
    /// executeChainRemoval may be pressed by anyone at all, the holder of the
    /// removal right included.
    error ChainProposalNeedsTheChainDoor();

    // Note: addArbiter/setChiefArbiter in ArbiterRegistryFacet revert with
    // SeatingHandedOver once the DAO is active, by the same decision of the
    // owner ("no manual seating" — the human steps out and only the
    // applyAsArbiter gate remains). That error is declared THERE, separately:
    // diamond facets have no shared error namespace, each declares its own.

    // -------- ENUM --------

    enum Cause {
        OverturnedVerdicts,  // verified by the chain (the arbiterMistakeStreak counter)
        Timeouts,            // verified by the chain (same counter — the chain does not tell them apart)
        Silence,             // verified by the chain (the "asked, no answer" record)
        Collusion,           // attested by a digest, not verified
        Leak,                // attested by a digest, not verified
        Other                // attested by a digest, not verified
    }

    // -------- EVENTS --------

    event ArbiterSuspended(address indexed arbiter, address indexed by, uint256 until);
    event ArbiterSuspensionLifted(address indexed arbiter, address indexed by);

    /// Removal of an arbiter for cause. `verifiedByChain` is the truth about
    /// whether the chain checked the code itself
    /// (OverturnedVerdicts/Timeouts/Silence) or merely attested the record with
    /// a digest of the evidence, without reading what is under it
    /// (Collusion/Leak/Other). That is the whole point of this cut: without the
    /// "proven on chain" flag both halves would read alike, and for the second
    /// half that reading would be a lie.
    event ArbiterRemovedForCause(
        address indexed arbiter,
        address indexed by,
        Cause   indexed cause,
        bool            verifiedByChain,
        bytes32         evidenceDigest,
        uint256         bondForfeited
    );

    /// The chief arbiter proposes a removal — he does not carry it out. A
    /// separate record under his own address (15 August 2026): the feed shows
    /// both who proposed and who agreed, instead of one record for two people.
    event RemovalProposed(
        address indexed arbiter,
        address indexed by,
        Cause   indexed cause,
        bytes32         evidenceDigest,
        uint256         at
    );
    event RemovalProposalWithdrawn(address indexed arbiter, address indexed by);

    /// An accusation against a real address stays on chain forever. The reply
    /// cancels nothing and returns nothing — it exists so that a reader of the
    /// chain sees TWO records instead of one (15 August 2026).
    event RemovalAnswered(address indexed arbiter, bytes32 replyDigest);

    /// Erasure of a proposal AT THE MOMENT of an actual removal — separate from
    /// RemovalProposalWithdrawn (that one means "changed my mind", this one
    /// means "it came to pass", 15 August 2026). It carries the fields of the
    /// ERASED proposal (not of the new state — that state is already gone), so
    /// that "proposed for X, removed for Y" is visible within a single
    /// transaction, without stitching two logs together by the arbiter's
    /// address.
    event RemovalProposalConsumed(
        address indexed arbiter,
        Cause   indexed proposedCause,
        address indexed proposedBy,
        bytes32         evidenceDigest,
        uint256         proposedAt
    );

    /// The accuser's words. A SEPARATE event rather than a field in
    /// ArbiterRemovedForCause/RemovalProposed: those are already indexed by the
    /// live subgraph, and changing their signature would stop the feed silently
    /// — graph-cli matches a log by its canonical signature, `indexed` included.
    /// The same technique already used for RemovalProposalConsumed: two logs in
    /// one transaction, stitched together by that transaction.
    ///
    /// `stage` separates a proposal (0) from a removal (1). It stays silent when
    /// there are no words: an empty string in the feed would erase the
    /// difference between "explained" and "kept quiet", and this whole mechanism
    /// rests on exactly that difference.
    event RemovalReasonGiven(
        address indexed arbiter,
        address indexed by,
        uint8   indexed stage,
        string          reason
    );

    /// The accused party's words. Symmetric to RemovalReasonGiven, but of a
    /// different modality: for the accuser it is a duty (when the chain stays
    /// silent), for the accused it is a right. Forcing a person to justify
    /// himself in public is not acceptable; nor is leaving the record one-sided
    /// — accusation in words, defence in a hash.
    event RemovalReplyGiven(address indexed arbiter, string reply);

    // -------- MODIFIERS --------

    /// ⚠️ THE CHIEF ARBITER CEASES TO EXIST ONCE THE DAO IS ACTIVE — here, in
    /// the modifier, and not in activateDAO() (16 August 2026).
    ///
    /// `setChiefArbiter` was closed under an active DAO, and it is the ONLY
    /// writer of `d.chiefArbiter` and the only way to zero it. So "the chief
    /// arbiter role is abolished" in fact meant the opposite: a sitting chief
    /// stayed in the slot FOREVER, with every right this modifier grants — to
    /// suspend, to lift a suspension, to propose a removal, to withdraw a
    /// proposal. An irremovable chief could suspend an arbiter every 72 hours
    /// indefinitely (during which that arbiter does not claim, does not
    /// finalise, CANNOT RESIGN and does not get his 50 USDC back), or lay down a
    /// removal proposal every 14 days — a constraint recorded as tolerable in
    /// ArbiterRegistryFacet._requireNoLiveRemovalProposal precisely because the
    /// chief can be replaced.
    ///
    /// The check lives in the modifier rather than in activateDAO() for two
    /// reasons: it holds whichever way the DAO was switched on (since 26 August
    /// 2026 only one way remains — the manual one — but a check in the modifier
    /// survives the appearance of a second), and it does not depend on the owner
    /// remembering to clear the slot in advance.
    ///
    /// ⚠️ AFTER THE HAND-OVER THE OWNER KEEPS TWO DOORS OUT OF FOUR. That count
    /// changed twice and silently both times — four → three (when the removal
    /// right became transferable), three → two (19 August 2026) — so it is now
    /// guarded by a scene rather than by a paragraph:
    /// `test_AfterHandoverTheOwnerKeepsExactlyTheTwoLightDoors`
    /// in `test/ArbiterRemovalForCauseIntegration.t.sol`.
    ///
    /// ⚠️ AND THE COUNT IS NOT TAKEN OVER THIS MODIFIER: in THIS facet exactly
    /// ONE function carries it, `suspendArbiter` (ArbiterRegistryFacet has its
    /// own copy of the modifier and its own carriers — that is a different
    /// count). The other three call `_requireOwnerOrChief` explicitly, because
    /// for each of them the role check is only one branch of several. What is
    /// counted here is "doors that historically ran under onlyOwnerOrChief", and
    /// that is worth keeping in mind while reading the word "modifier" below.
    ///
    /// KEPT, and both of them light:
    ///   • `suspendArbiter` — reversible, expires by itself;
    ///   • the LIGHT branch of `liftSuspension` — lifting an ORDINARY
    ///     suspension. The heavy half (a window set by a removal, and since
    ///     18 August 2026 a window under a live accusation by the chain) is
    ///     lifted only by the holder of the removal right.
    ///
    /// LOST, both through `RemovalHandedOver` inside those functions' own
    /// branches and NOT through this check:
    ///   • `proposeRemoval` — 17 August 2026;
    ///   • `withdrawProposal` — 19 August 2026.
    ///
    /// ⚠️ WHY THOSE BRANCHES ARE WRITTEN THERE AND NOT HERE, and why "one more
    /// condition here would do" is the wrong idea: THIS CHECK LETS THE OWNER
    /// THROUGH ALWAYS. Its DAO gate stands on the CHIEF's branch and only on it
    /// (see the body below). A door that wants to close on hand-over is obliged
    /// to say so in its own voice.
    /// The body of the modifier was extracted into a separate function
    /// (16 August 2026) because `liftSuspension` grew TWO permission branches
    /// and needs to call this check in one of them rather than in all. The
    /// modifier below now only calls it — no copy of the condition is created,
    /// and the role is still described in exactly one place.
    function _requireOwnerOrChief(ArbiterRegistryStorage.Data storage d) private view {
        if (msg.sender != OwnershipLib.contractOwner()) {
            if (_isDaoActive(d) || msg.sender != d.chiefArbiter) revert NotOwnerOrChief();
        }
    }

    modifier onlyOwnerOrChief() {
        _requireOwnerOrChief(ArbiterRegistryStorage.data());
        _;
    }

    // -------- ERC-2771 SENDER --------

    /// A copy of the one in ArbiterRegistryFacet — facets do not inherit from
    /// each other, and this project has no shared base contract. The only user
    /// path that calls it is respondToRemoval; every other function of the facet
    /// stays on the raw msg.sender (administrative, not gasless — recorded as
    /// a documented exception to the ERC-2771 sender-check build gate).
    ///
    /// ⚠️ WHAT ACTUALLY GUARDS THIS (16 August 2026; the numbers below are
    /// MEASUREMENTS, not reasoning).
    ///
    /// An earlier version of this comment promised that the body "must match
    /// byte for byte — checked by test_MsgSenderMatchesRegistry". The promise
    /// was false twice over: no byte-for-byte check exists at all, and the named
    /// test (test/ArbiterRemovalForCause.t.sol) drives ONLY respondToRemoval
    /// through the forwarder — that is, it proves THIS copy works and says
    /// nothing about agreement with the registry's. The test itself was renamed
    /// on 16 August 2026 after what it does:
    /// test_RespondToRemovalThroughForwarderCreditsHuman.
    ///
    /// How things actually stand: EACH of the two copies is proven
    /// INDEPENDENTLY and against an EXTERNAL truth — the signer's address, not
    /// the neighbouring facet. Measurement: corrupting the original
    /// (ArbiterRegistryFacet._msgSender → `sender = msg.sender`) gives 6 reds,
    /// five of them the registry's own gasless paths (fundDispute,
    /// withdrawDisputeBounty, recordNoResponse, recordPresentationDigest,
    /// setArbiterChatKey), the sixth the differential below; corrupting the copy
    /// gives 2 reds. Neither can drift apart silently.
    ///
    /// What that edit added:
    /// test/ArbiterRemovalForCauseIntegration.t.sol::
    /// test_MsgSenderAgreesAcrossBothFacetsOnOneForwarder — the only place where
    /// both implementations run on ONE diamond, ONE storage, with ONE real
    /// MinimalForwarder and ONE signer, and their answers are checked against
    /// each other. An honest caveat: it is NEVER the only red — on any
    /// corruption the corrupted side's own test goes red next to it. It is not a
    /// guard, it is a check on the seam: it catches the PAIR drifting apart (for
    /// instance, the copy starting to read a different storage field — measured,
    /// 2 reds, both about this pair), not whether each works on its own.
    ///
    /// A byte-for-byte comparison of the text does not exist and was never set
    /// up. It would cost widening fs_permissions in foundry.toml from `./out` to
    /// `./src` — opening the sources to the tests for the sake of equal
    /// whitespace and comments. A divergence that does not change behaviour does
    /// no harm; a divergence that does change behaviour goes red anyway, as
    /// measured above.
    function _msgSender() internal view returns (address sender) {
        address forwarder = FactoryStorage.store().trustedForwarder;
        if (msg.sender == forwarder && msg.data.length >= 20) {
            assembly { sender := shr(96, calldataload(sub(calldatasize(), 20))) }
        } else {
            sender = msg.sender;
        }
    }

    // -------- SUSPENSION --------

    /// A fast, reversible stop. It accuses nobody and takes nothing away: that
    /// is why the chief arbiter holds it too, and why it stays with the owner
    /// after removal is handed over to a vote.
    function suspendArbiter(address arbiter) external onlyOwnerOrChief {
        if (arbiter == address(0)) revert ArbiterZeroAddress();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (!d.isArbiter[arbiter]) revert NotAnArbiter();

        // From the CURRENT moment, not added to a previous deadline: otherwise
        // two presses in a row hold someone's money for six days instead of
        // three.
        uint256 until = block.timestamp + ArbiterRegistryStorage.SUSPENSION_WINDOW;
        d.suspendedUntil[arbiter] = until;
        emit ArbiterSuspended(arbiter, msg.sender, until);
    }

    /// Lift ahead of time. A separate function rather than "suspend for zero":
    /// in the feed those are different events, and a reader needs to see the
    /// lifting as such.
    ///
    /// ⚠️ ONE BUTTON, TWO WEIGHTS (16 August 2026). The earlier version checked
    /// NOTHING — neither status, nor cause, nor who imposed the window — and was
    /// available to the chief arbiter. Two consequences followed at once:
    ///
    ///   • the chief undid the owner's weightiest action in a single
    ///     transaction. After removeArbiterForCause the person is no longer an
    ///     arbiter, and suspendArbiter requires isArbiter — so the owner could
    ///     not put the window back. And that window holds money: finalizeVerdict
    ///     is gated on the suspension of the VERDICT'S ARBITER, and anyone at
    ///     all may call it;
    ///   • the same call silenced the AUTOMATON: the same window is set by the
    ///     automatic demotion (_recordArbiterMistake), which is deliberately
    ///     built to work without a human.
    ///
    /// The discriminator is `removedAt`, and it already exists: both removal
    /// doors write it and both entry doors (addArbiter/applyAsArbiter) clear it.
    /// So for a serving arbiter it is always zero, and an ordinary suspension
    /// stays light, as intended: the chief lifts it, that is his job.
    ///
    /// ⚠️ What must be read is `removedAt` SPECIFICALLY, not "how many times he
    /// was removed" from the permanent history (removalCount/lastRemovalAt). The
    /// permanent record is never erased — a gate on it would mean that a person
    /// removed once and later reseated deprives the chief forever of the right
    /// to lift an ordinary suspension from him. What is needed here is the fact
    /// "a removal is CURRENT, not yet undone", and that is exactly `removedAt`.
    /// Guarded by a test rather than by a docstring:
    /// ArbiterRemovalForCauseIntegration::
    /// test_ChiefStillLiftsOrdinarySuspensionAfterReseat — removed, reseated,
    /// suspended in the ordinary way, chief lifts it. It exists because
    /// simulating this mistake produced 0 reds out of 831.
    ///
    /// ⚠️ THE RIGHT TRAVELS WITH THE RIGHT TO REMOVE (16 August 2026). Not "the
    /// owner" in general, but WHOEVER HOLDS REMOVAL TODAY: the owner before the
    /// hand-over, the named successor after it (_removalAuthority, one
    /// expression serving both places). The earlier version compared against the
    /// owner always, which directly contradicted the rationale for which
    /// removeArbiterForCause pushes the owner out: "there is no road back —
    /// otherwise collusion and a leaked correspondence would become impossible
    /// to act on at all". Measured during review: after the hand-over the new
    /// authority could not lift its own window (the modifier did not see it),
    /// while the owner lifted SOMEONE ELSE'S, after which nothing can put the
    /// suspension back.
    ///
    /// Hence the removed modifier as well: `onlyOwnerOrChief` would not let the
    /// successor into the body at all, and after the hand-over NOBODY would open
    /// the window — a door with no one to open it is worse than a door held by
    /// the owner (the same rationale recorded in removeArbiterForCause about a
    /// zero daoAddress). The ordinary branch runs under the same check as
    /// before — _requireOwnerOrChief, that very modifier body, called
    /// explicitly.
    ///
    /// ⚠️ An honest caveat about the origin of the window (found in review,
    /// 16 August 2026). The discriminator answers "is a removal standing against
    /// this person", not "was the window set by that removal", and on one live
    /// path the two already diverge: `applyAsArbiter` calls
    /// `clearRemovalRecord(..., false)` — it erases `removedAt` while
    /// DELIBERATELY leaving `suspendedUntil` in place (otherwise a removed
    /// arbiter would buy his way past the window with a fresh bond). After
    /// re-enrolling himself the person sits with a live removal window and a
    /// zero discriminator, so this branch does not fire on him.
    ///
    /// ⚠️ THE ARGUMENT "THERE IS NO HOLE TODAY" HAS BEEN CORRECTED. The earlier
    /// version said: "there is no hole because applyAsArbiter requires an active
    /// DAO, and under an active DAO _requireOwnerOrChief does not see the chief
    /// at all". That is an analysis of the CHIEF only, and for him it holds. For
    /// the OWNER it does not, and the remainder is real:
    ///
    ///   after the removal right is handed over, the owner still lifts the
    ///   window of SOMEONE ELSE'S removal in TWO transactions — the removed
    ///   arbiter calls `applyAsArbiter` (the window survives, by the rule
    ///   above), `removedAt` goes to zero, and the ordinary branch below lets
    ///   the owner in, because the discriminator is already zero.
    ///
    /// This is not a regression: before the removal right became transferable
    /// the same thing took ONE transaction. And it is not fixed here — the only
    /// real fix is a memory of WHO imposed the suspension, which is declared out
    /// of scope for this work and stands as a known open item together with the
    /// same caveat about the window's origin. The invariant today rests on two
    /// independent predicates agreeing, and no test compares that pair.
    /// ⚠️ AND SINCE 18 AUGUST 2026 THE DISCRIMINATOR HAS A SECOND HALF. The
    /// automatic path no longer unseats on the third mistake — it suspends and
    /// accuses — so `removedAt` is zero on a man the chain has just stopped,
    /// and without this half the chief would lift the automatic suspension in
    /// ONE transaction. That is exactly the bypass closed above ("the same call
    /// silenced the AUTOMATON"), walking back in through a change made two
    /// doors away, and it is why the guard moved with the behaviour rather than
    /// being left to rot next to it.
    ///
    /// The chief is not locked out of the case, and deliberately: he may
    /// withdrawProposal the chain's accusation — the owner's decision — and once
    /// it is withdrawn this gate falls away and the suspension is his to lift
    /// like any other. Two transactions, both with his name in the feed, instead
    /// of one silent one.
    function liftSuspension(address arbiter) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        // ⚠️ `hasLiveProposal`, NOT `proposedAt != 0` (18 August 2026).
        // Staleness is one rule and it already has a home; the first
        // version of this line was written without it and was the only one of
        // the four proposal predicates in this file that ignored PROPOSAL_TTL.
        // The cost was measured, not imagined: an accusation the chain laid and
        // nobody executed goes stale after fourteen days and can never be
        // withdrawn by anyone who cares to — so the arbiter it was laid against
        // would have been barred from ordinary suspension relief by the chief
        // FOREVER, on the strength of a record that stops meaning anything.
        //
        // An empty record needs no separate branch either: hasLiveProposal
        // answers false on `proposedAt == 0`, so the `by` read below never
        // stands alone.
        bool accusedByChain =
            hasLiveProposal(arbiter) && d.removalProposals[arbiter].by == address(0);

        if (d.removedAt[arbiter] != 0 || accusedByChain) {
            (address authority, ) = _removalAuthority(d);
            if (msg.sender != authority) revert RemovalSuspensionIsRemovalAuthorityOnly();
        } else {
            _requireOwnerOrChief(d);
        }

        delete d.suspendedUntil[arbiter];
        emit ArbiterSuspensionLifted(arbiter, msg.sender);
    }

    // -------- REMOVAL FOR CAUSE --------

    /// The chain verifies only what it sees in its own state. The first three
    /// codes are verifiable, the last three are not, and the verifiedByChain
    /// flag in the event tells the reader the truth about which case this is.
    function _isChainVerifiable(Cause cause) private pure returns (bool) {
        return cause == Cause.OverturnedVerdicts
            || cause == Cause.Timeouts
            || cause == Cause.Silence;
    }

    /// ONE ceiling for all three doors: both accusation doors (proposeRemoval,
    /// removeArbiterForCause) and the defence door (respondToRemoval). A shared
    /// rule lives in one place, not as a copy on each side.
    ///
    /// ⚠️ There used to be a copy here, and that was measured rather than
    /// suspected (18 August 2026): before the fix, respondToRemoval counted the
    /// length with a line of its own, and the mutation "count characters instead
    /// of bytes", planted in _requireReason, did NOT touch the reply door at
    /// all. One rule had two independent homes, and they could drift apart
    /// silently — the defence would get half the room the accusation gets, and
    /// only somebody writing in a non-Latin script would notice.
    ///
    /// The length is returned to the caller because the caller needs it once
    /// more, each for a purpose of its own: `_requireReason` uses it to check
    /// whether words are mandatory, `respondToRemoval` uses it to gate the event
    /// (no empty words ever appear in the feed). Both accusation doors read the
    /// length again just before their `emit` — today that is the only repetition
    /// left, and a harmless one: `bytes(s).length` is not a rule but a question
    /// asked of the same string. Computing it here and discarding it would
    /// recreate the same copy half a line further down.
    function _requireWithinCap(string calldata words) private pure returns (uint256 len) {
        len = bytes(words).length;
        if (len > MAX_REASON_BYTES) revert ReasonTooLong(len);
    }

    /// Mandatoriness belongs to the ACCUSER only, and therefore lives apart from
    /// the ceiling. The asymmetry is neither an accident nor an oversight: for
    /// the accuser words are a duty (where the chain stays silent), for the
    /// accused they are a right. Forcing a person to justify himself in public
    /// is not acceptable. Splitting the shared part from the differing part
    /// makes that difference visible in the code, instead of leaving it to the
    /// discipline of whoever edits this file in six months.
    ///
    /// One rule for both accusation doors (proposeRemoval and
    /// removeArbiterForCause). There must be no copy here: were the two to
    /// drift, they would give a proposal that passes without words and a removal
    /// that does not — that is, a pause in which the accused has nothing to
    /// read.
    ///
    /// Order of checks: length BEFORE mandatoriness. Otherwise an accuser who
    /// sent 5 kilobytes on a verifiable code would get "ok" instead of a
    /// rejection, and calldata of that size would reach the chain.
    function _requireReason(bool verified, string calldata reason) private pure {
        uint256 len = _requireWithinCap(reason);
        if (!verified && len == 0) revert ReasonRequired();
    }

    /// Every verifiable code looks at ITS OWN fact. Merging them into a single
    /// check is not possible: `Silence` would then pass on the overturn counter,
    /// meaning the chain would attest something other than what the record says.
    ///
    /// ⚠️ An honest caveat about the first two: `OverturnedVerdicts` and
    /// `Timeouts` both come down to ONE counter, `arbiterMistakeStreak` — it is
    /// incremented by `overturnVerdict` and by `notifyArbiterTimeout` alike, and
    /// the chain cannot tell them apart after the fact. So the choice between
    /// these two codes is the owner's statement about WHAT happened, while the
    /// chain verifies only that there was a streak.
    ///
    /// ⚠️ THIS USED TO SAY "they can only be separated by a second counter, and
    /// that is a separate piece of work", and half of that sentence went stale on
    /// 21 August 2026. The second counter NOW EXISTS — `overturnedVerdicts` —
    /// and it grows on exactly the two overturn paths, leaving timeouts aside.
    /// The chain can already tell "his verdicts were overturned" from "he ran out
    /// of time" using that number.
    ///
    /// The check below still does NOT read it, and that is not forgetfulness:
    /// the "clean / overturned" pair was introduced by the owner's decision at
    /// the levels "visible → counted", and it has no thresholds and no
    /// consequences whatsoever. Hanging `overturnedVerdicts` here would create a
    /// third level — "has an effect" — under the guise of a refinement, and do it
    /// with a cumulative number that punishes long service. Whoever decides to
    /// change that is taking a new decision, not finishing an old one.
    ///
    /// ⚠️ THE ONLY CALLER IS `removeArbiterForCause` (18 August 2026).
    /// `executeChainRemoval` does NOT call this function, and called it only
    /// briefly: by the owner's decision, an accusation laid down by the chain is
    /// evidence in itself, whereas re-asking the counter two days later asks a
    /// different question ("is this still true today"), and an answer to that is
    /// bought with a single clean verdict. The full analysis is in the docstring
    /// of that button.
    ///
    /// ⚠️ CAUSE IS CONSUMED BY HALVES (it used to say "not consumed at all" —
    /// 16 August 2026; half of it was fixed on 18 August). Carried through to a
    /// removal, it is consumed: `_performRemoval` zeroes the counter. Not carried
    /// through, it remains, and rightly so. Piece by piece:
    ///
    ///   • `arbiterMistakeStreak` — ⚠️ HALF OF THIS WAS FIXED ON 18 AUGUST 2026.
    ///     It used to say: "a removal for cause does NOT zero the counter, so an
    ///     owner who reinstates a wrongly removed arbiter through addArbiter
    ///     brings him back with the counter still at the threshold — the same
    ///     fact justifies a removal AGAIN, without a single new mistake". Now
    ///     BOTH doors zero it: `_performRemoval`, the shared removal body, does
    ///     it in one line for both callers, and the evidence is spent by the
    ///     removal built on it.
    ///
    ///     What remains unspent: a cause that was raised and NOT carried through
    ///     to a removal (the proposal went stale, a person withdrew it, or the
    ///     removal was simply never pressed) — the counter stands and serves the
    ///     next attempt. That is no longer "evidence outliving its own
    ///     execution" but "evidence outliving a non-execution", and it cannot be
    ///     otherwise: the arbiter's mistakes did not go anywhere because the
    ///     accuser changed his mind.
    ///   • `disputeNoResponseAtBy` is never erased, by design (see the field in
    ///     ArbiterRegistryStorage: an erasable record would hand the arbiter the
    ///     power to reset its timestamp). But `Silence` checks only the PRESENCE
    ///     of the record and knows nothing about how the dispute ended. An
    ///     arbiter who honestly recorded a party's silence and then saw the
    ///     dispute through to finalisation carries a ready-made cause for his own
    ///     removal forever, stamped "verified by the chain".
    ///
    /// The cure (not now): remember the moment of the previous removal and
    /// require the evidence to be NEWER than it (`removedAt` already exists for
    /// that), and for `Silence` — do not count a record on a dispute that reached
    /// a finalised verdict by that same arbiter.
    function _requireProven(
        ArbiterRegistryStorage.Data storage d,
        address arbiter,
        Cause   cause,
        address disputeRef
    ) private view {
        if (cause == Cause.Silence) {
            if (disputeRef == address(0)) revert DisputeRefRequired();
            // The silence record is laid down by the arbiter himself through
            // recordNoResponse: it means "the party was asked and did not
            // answer". As a cause for REMOVAL it reads the other way round —
            // the arbiter recorded the silence and still failed to see the
            // dispute through. Hence its presence is checked, not its absence.
            if (d.disputeNoResponseAtBy[disputeRef][arbiter] == 0) {
                revert CauseNotProven(uint8(cause));
            }
            return;
        }

        if (disputeRef != address(0)) revert DisputeRefNotApplicable();
        if (d.arbiterMistakeStreak[arbiter] < MISTAKE_THRESHOLD) {
            revert CauseNotProven(uint8(cause));
        }
    }

    /// Mirror of DAO_THRESHOLD from ArbiterRegistryFacet. Found in review
    /// (15 August 2026): reading only `daoActiveManual` was half the truth — on
    /// organic growth of `uniqueActiveUsers` the DAO would have switched itself
    /// ON, addArbiter/setChiefArbiter (which call isDaoActive() directly, inside
    /// their own contract) would already be refusing, while
    /// removeArbiterForCause would still obey the owner — an asymmetry between
    /// "the human has stepped out" and "the human is still here", exactly where
    /// both doors are obliged to close together. Agreement with the original is
    /// checked by the test test_DaoThresholdMatchesRegistry.
    /// ⚠️ 100 000 → 10 000 (26 August 2026), in step with
    /// ArbiterRegistryFacet.DAO_THRESHOLD, checked by test_DaoThresholdMirror*.
    /// `Treasury.DAO_THRESHOLD` is a THIRD constant, still 100 000, and stays
    /// so until another treasury is deployed: that contract is immutable.
    uint256 private constant DAO_THRESHOLD_MIRROR = 10_000;

    /// A ratchet: the removal right leaves together with the DAO activation and
    /// does not come back — activateDAO() is one-way and the flag is cleared
    /// nowhere in all of src/. The same expression as
    /// ArbiterRegistryFacet.isDaoActive(), and that condition matters more than
    /// the expression itself: separate semantics for the two halves would be a
    /// new seam.
    /// ⚠️ THE EARNED HALF IS GONE HERE TOO (26 August 2026), and
    /// it had to go in the same change: this predicate exists to say the same
    /// thing as ArbiterRegistryFacet.isDaoActive(), and one facet answering
    /// "governance is live" while its neighbour answers "not yet" would be a
    /// seam of its own. What the mirror now mirrors is one flag.
    ///
    /// DAO_THRESHOLD_MIRROR is still declared and still goes out through
    /// getDaoThresholdMirror(): the number did not stop existing, it stopped
    /// switching anything on. It is now the condition `activateDAO()` checks.
    function _isDaoActive(ArbiterRegistryStorage.Data storage d) private view returns (bool) {
        return d.daoActiveManual;
    }

    /// WHO IS ENTITLED TO REMOVE TODAY — the single place where this is computed
    /// (16 August 2026). It answers two things at once: the address holding the
    /// right, and whether that right has moved away — because callers need both,
    /// and computing them separately would split the condition into copies.
    ///
    /// Before that change the "handed over" predicate stood here as a single
    /// copy, inside removeArbiterForCause, and `liftSuspension` knew nothing
    /// about it. There are already three copies of this condition across the
    /// project (here, ArbiterRegistryFacet._requireSeatingNotHandedOver,
    /// ArbiterRegistryFacet.setDAOAddress), and a fourth one written in its own
    /// words would be exactly the kind of seam this branch was catching: two
    /// expressions, a promise that "they agree", and nothing that goes red when
    /// they do not.
    ///
    /// ⚠️ On `&& d.daoAddress != address(0)`: the hand-over latches only once a
    /// successor is ACTUALLY NAMED. Without the second half, in the window
    /// "the threshold was earned by outsiders, no successor appointed yet" the
    /// right would move to the zero address — that is, nobody would open the
    /// door. The full analysis is in the docstring of removeArbiterForCause.
    function _removalAuthority(ArbiterRegistryStorage.Data storage d)
        private
        view
        returns (address authority, bool handedOver)
    {
        handedOver = _isDaoActive(d) && d.daoAddress != address(0);
        authority = handedOver ? d.daoAddress : OwnershipLib.contractOwner();
    }

    /// `disputeRef` is read ONLY by the Silence code: silence is a fact about a
    /// specific dispute (`disputeNoResponseAtBy[deal][arbiter]`), and without the
    /// dispute address there is nothing to check it against. For the other codes
    /// the parameter must be zero — otherwise an address unrelated to anything
    /// would settle into the record, and a reader would conclude that the
    /// removal has something to do with that deal.
    ///
    /// The removal right is handed over rather than locked away, and the
    /// hand-over latches ONLY once a successor really exists: while `daoAddress`
    /// is zero the owner calls, however many paths may have turned
    /// `isDaoActive()` on. Once a successor is named, only he calls (not through
    /// onlyOwnerOrDAO from ArbiterRegistryFacet: that modifier lets the owner in
    /// ALWAYS, whereas here, after the hand-over, there is no road back for the
    /// owner — otherwise the automatic path (only what the chain can see) would
    /// be the sole remaining defence, and collusion or a leaked correspondence
    /// would become impossible to act on at all).
    ///
    /// ⚠️ "No road back for the owner" rests on one more guard, not only on this
    /// one: `ArbiterRegistryFacet.setDAOAddress`, once the DAO is active, also
    /// requires the CURRENT daoAddress to be the caller, not the owner
    /// (otherwise the owner would take this function back through
    /// `activateDAO()` → `setDAOAddress(his_own_address)`). Both halves must
    /// lock in step — fixing this one without fixing that one would be worth
    /// nothing.
    ///
    /// ⚠️ `reason` is the accuser's DUTY exactly where the chain stays silent
    /// (design of 17 August 2026). Before that change the public record of a
    /// removal contained not a single word: `Cause` is a numeric code, and the
    /// event carries addresses, a code, a digest and an amount. The name
    /// "removal for cause" promised an explanation that existed nowhere. The
    /// rule fell onto the already existing `_isChainVerifiable` without a new
    /// condition: the three verifiable codes the chain explains by itself, the
    /// three taken on trust are obliged to explain themselves in words.
    function removeArbiterForCause(
        address arbiter,
        Cause   cause,
        bytes32 evidenceDigest,
        address disputeRef,
        string calldata reason
    ) external {
        if (arbiter == address(0)) revert ArbiterZeroAddress();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        // ⚠️ THE SAME PREDICATE AS THE NEIGHBOURING DOOR (16 August 2026).
        // This used to be a bare `_isDaoActive(d)`, which differed from
        // ArbiterRegistryFacet._requireSeatingNotHandedOver and from
        // ArbiterRegistryFacet.setDAOAddress, where the condition is complete.
        //
        // ⚠️ References BY FUNCTION NAME, not by line number. Two line numbers
        // stood here, `:855` and `:1956`; both drifted while neighbouring work
        // was done and pointed at the wrong place, silently. The rule for the
        // future: a line number in a comment lives until the first edit to its
        // NEIGHBOUR and goes stale without a single sign. A function name is
        // found by grep and survives the move.
        //
        // The cost of divergence was measured, not assumed: isDaoActive() is
        // turned on not only by the manual activateDAO() (which has its own
        // DaoAddressNotSet guard) but also by the EARNED threshold
        // uniqueActiveUsers >= DAO_THRESHOLD — that is, by the actions of
        // strangers, without a single transaction from this side. In the window
        // "the threshold is earned, no successor named yet" the old condition
        // degenerated into `msg.sender != address(0)` — true for EVERYONE, so
        // nobody could call removeArbiterForCause. A door nobody can open is
        // worse than a door held by the owner: the only path to removing an
        // arbiter for cause would be switched off by outsiders.
        //
        // The window is closed by a single transaction from the owner
        // (setDAOAddress in that state requires precisely him), but until then
        // the door must stay working — exactly what the public
        // docs/DECENTRALIZATION.md, Stage 3, promises the reader: "once
        // governance is active AND a successor address has been named".
        //
        // ⚠️ The condition itself moved into _removalAuthority (16 August 2026)
        // — not for tidiness, but because it acquired a SECOND reader:
        // liftSuspension. The right to cancel a removal window must travel with
        // the right to remove, and be computed from one expression rather than
        // from two similar ones. Behaviour here did not change by a byte: the
        // branch and both errors are the same.
        (address authority, bool handedOver) = _removalAuthority(d);
        if (msg.sender != authority) {
            if (handedOver) revert RemovalHandedOver();
            revert NotOwner();
        }

        if (!d.isArbiter[arbiter]) revert NotAnArbiter();

        // ⚠️ REMOVAL ONLY RUNS THROUGH A PROPOSAL THAT HAS SAT (design of
        // 17 August 2026). Before this change the proposal
        // existed but was OPTIONAL and changed nothing: removal was a single
        // button, and the person learned of it after the fact — sentence
        // first, word after.
        //
        // Execution window: [proposedAt + REMOVAL_DELAY, proposedAt +
        // PROPOSAL_TTL). The lower bound is inclusive, the upper exclusive,
        // exactly as in hasLiveProposal — diverge from it and the button would
        // go dark before the feed stops showing the accusation as live.
        //
        // Read HERE rather than through hasLiveProposal(): that one answers
        // "does an accusation stand", while FOUR different refusals with four
        // different hints are needed here — "no accusation", "not your door",
        // "too early", "expired". One boolean answering four questions would
        // leave the form guessing.
        ArbiterRegistryStorage.RemovalProposal storage p = d.removalProposals[arbiter];
        uint256 proposedAt = p.proposedAt;
        if (proposedAt == 0) revert NoLiveProposal();

        // ⚠️ THE CHAIN'S OWN ACCUSATION IS NOT EXECUTED HERE — it has its own
        // door, and this refusal says which (18 August 2026). Placed
        // immediately after "is there a record" and before any clock, exactly
        // as NotAChainProposal is on the other side: the two doors give the
        // same answer to the same question, from opposite ends.
        //
        // No disclosure concern on this side — the caller already passed the
        // role check above and is the removal authority — so the position here
        // is about a useful answer rather than a guarded one: "wrong door" is
        // what he needs to read, not "too early".
        if (p.by == address(0)) revert ChainProposalNeedsTheChainDoor();

        if (block.timestamp < proposedAt + REMOVAL_DELAY) {
            revert RemovalTooEarly(proposedAt + REMOVAL_DELAY);
        }
        if (block.timestamp >= _proposalDeadline(p)) revert ProposalStale(proposedAt);

        // EXACTLY the cause code is compared — the thing the person was warned
        // about. Not the whole application: the digest, the dispute reference
        // and the words are supplied afresh, by the accuser's own arguments,
        // and the older rule "a proposal is a signal in the feed, not an
        // argument of the removal function" is not repealed by this. It would
        // be repealed if removal READ anything out of the proposal and put it
        // into the record; it still reads nothing — it merely refuses to
        // execute an accusation that was never served.
        if (p.cause != uint8(cause)) {
            revert CauseDiffersFromProposal(p.cause, uint8(cause));
        }

        // ⚠️ THE MANUAL DOOR STILL RE-PROVES, AND THE ASYMMETRY WITH
        // executeChainRemoval IS DELIBERATE (18 August 2026). It was checked
        // before it was decided: proposeRemoval
        // does NOT call _requireProven — it checks the ROLE, the digest and the
        // words, nothing else — so this line is the only thing standing between
        // a made-up verifiable cause and a removal carrying the chain's own
        // "verifiedByChain: true" stamp. Dropping it for symmetry would let
        // anyone with the removal right accuse an arbiter of overturned
        // verdicts he never had, wait 48 hours, and remove him with the chain
        // vouching for it.
        //
        // ⚠️ SO THE HOLE THE CHAIN DOOR JUST CLOSED IS STILL OPEN HERE, and
        // saying so beats leaving it to be rediscovered: a proposal laid at
        // streak 2 becomes unexecutable if the arbiter carries one dispute
        // through cleanly, because finalizeVerdict zeroes the counter.
        //
        // ⚠️ "PROPOSE AGAIN" UNDERSTATES IT. Proposing again
        // changes nothing on its own — the counter is at zero, so the accuser
        // needs TWO FRESH JUDICIAL MISTAKES before any proposal on this cause
        // can be executed at all. The accusation is not delayed, it is dead,
        // and the evidence has to be earned over.
        //
        // ⚠️ AND WITHDRAWING IT IS NOT ALWAYS AVAILABLE EITHER. While the dead
        // proposal stands, resignAsArbiter is barred; clearing it belongs to
        // the removal authority and the chief — and after the handover to the
        // successor alone, because withdrawProposal has its own RemovalHandedOver
        // branch since 19 August 2026. If he does not, the arbiter waits out
        // PROPOSAL_TTL with an accusation that can neither be executed nor
        // lifted.
        //
        // Closing it properly means proving the cause AT PROPOSAL time and
        // letting the record carry the finding, which is a change to the
        // accusation door and not to this one; it remains a known open item.
        bool verified = _isChainVerifiable(cause);
        if (verified) {
            _requireProven(d, arbiter, cause, disputeRef);
        } else {
            if (disputeRef != address(0)) revert DisputeRefNotApplicable();
            // The chain verifies nothing here and does not pretend to — but an
            // empty record will not do either: zero has no preimage to show.
            if (evidenceDigest == bytes32(0)) revert EvidenceRequired();
        }
        _requireReason(verified, reason);

        // Snapshot of the proposal BEFORE _performRemoval — that one erases
        // removalProposals through clearSeat (15 August 2026: the delete used to
        // stand only here, so a person who left through resignAsArbiter or was
        // unseated by the automatic path carried a live proposal away with him —
        // hasLiveProposal would keep answering true for up to two weeks against
        // an arbiter who is already gone and cannot clear the record about
        // himself). The snapshot is needed ONLY for the event below — after the
        // cleanup there is nothing left to read.
        ArbiterRegistryStorage.RemovalProposal memory consumedProposal = d.removalProposals[arbiter];

        uint256 forfeited = _performRemoval(d, arbiter);

        // The permanent half of the record. The library does the encoding — what
        // is passed here is the raw cause number, exactly the one that travels
        // in the ArbiterRemovedForCause event below. THIS line is the difference
        // between the two callers of _performRemoval: the removal body is
        // shared, the cause record is each caller's own.
        ArbiterRegistryStorage.recordRemovalForCause(d, arbiter, uint8(cause));

        emit ArbiterRemovedForCause(arbiter, msg.sender, cause, verified, evidenceDigest, forfeited);

        // A separate event carrying the fields of the ERASED proposal — visible
        // within a single transaction (both events sit in one log), without
        // stitching it to RemovalProposed by the arbiter's address through the
        // history.
        //
        // ⚠️ THE CONDITION BELOW CANNOT BE FALSE ANY MORE, and saying so beats
        // letting the next reader take it for a guard (17 August 2026). The
        // gate at the top of this function already refused `proposedAt == 0`
        // with NoLiveProposal, and nothing between there and here clears the
        // record — so every removal that reaches this line consumed a real
        // proposal. Kept rather than deleted because deleting it changes no
        // behaviour and no test could tell the two versions apart; the honest
        // note is the part that has value. The scene it used to serve — a
        // removal with no preceding proposal — is gone with the test that
        // played it (see test/ArbiterRemovalForCause.t.sol).
        //
        // WHAT WOULD MAKE IT REACHABLE AGAIN — so the next reader neither
        // deletes it as litter nor has to guess. Exactly three things, and any
        // one of them is enough:
        //   • the `proposedAt == 0` refusal at the top weakens — a "fast path"
        //     for some cause, an exemption for the successor, anything that
        //     lets a removal run without a standing proposal;
        //   • something between that refusal and the snapshot below starts
        //     clearing `d.removalProposals[arbiter]` — today nothing does, and
        //     the snapshot is deliberately taken BEFORE clearSeat for that
        //     reason;
        //   • the snapshot moves ABOVE the gate, at which point it can again
        //     be read on a record the gate was going to reject.
        // If any of those happens, this branch goes back to carrying weight
        // and needs a test of its own; until then it carries none.
        if (consumedProposal.proposedAt != 0) {
            emit RemovalProposalConsumed(
                arbiter,
                Cause(consumedProposal.cause),
                consumedProposal.by,
                consumedProposal.evidenceDigest,
                consumedProposal.proposedAt
            );
        }

        // The words go out as a separate log of the same transaction, and only
        // if there are any: an empty string in the feed would erase the
        // difference between "explained" and "kept quiet".
        if (bytes(reason).length != 0) {
            emit RemovalReasonGiven(arbiter, msg.sender, REASON_STAGE_REMOVAL, reason);
        }
    }

    /// THE BODY OF A REMOVAL, and the only copy of it (18 August
    /// 2026). Two doors now reach it — removeArbiterForCause, where a person
    /// accuses and a person executes, and executeChainRemoval, where the chain
    /// did both — and everything they do IDENTICALLY lives here: the seat, the
    /// roster, the bond, the mark of removal, the streak, the suspension and
    /// the provenance.
    ///
    /// What each caller keeps for itself is exactly what differs: the record of
    /// the cause (recordRemovalForCause against recordAutomaticRemoval) and its
    /// own event. A second copy of the body was refused for the reason already
    /// written on clearSeat's docstring — three copies of one paragraph diverge
    /// at the first edit, and the divergence here would be a removal that
    /// forgets to forfeit or forgets to suspend.
    ///
    /// ⚠️ THE STREAK IS ZEROED HERE, AND THIS IS NEW FOR THE MANUAL DOOR.
    /// Before 18 August 2026 only the automatic path cleared it, and _requireProven
    /// said so out loud as a known defect: an owner who re-seated a wrongly
    /// removed arbiter through addArbiter handed him back WITH the counter at
    /// the threshold, so the same evidence justified removing him a second time
    /// without one new mistake. Both doors clear it now, and the evidence is
    /// spent by the removal it paid for.
    ///
    /// ⚠️ REMOVAL IMPLIES SUSPENSION (16 August 2026). Without it the strong
    /// measure was WEAKER than the weak one:
    /// submitVerdict is gated by the CLAIM, not by the seat, and removal
    /// touches neither disputeClaims nor openClaimCount — so a man removed this
    /// minute filed verdicts on every dispute he held, a passer-by finalised
    /// them a day later, and the escrow went to whoever had paid him.
    /// suspendArbiter is no help by then: it reverts NotAnArbiter on a man who
    /// is no longer one. The mark expires by itself, as every suspension does.
    function _performRemoval(ArbiterRegistryStorage.Data storage d, address arbiter)
        private
        returns (uint256 forfeited)
    {
        // A removal is not a voluntary exit: the bond is forfeited into the
        // arbiter vault rather than returned (the opposite of resignAsArbiter,
        // and deliberately so — this is a penalty, not a parting).
        forfeited = d.arbiterBond[arbiter];
        if (forfeited > 0) {
            d.arbiterBond[arbiter] = 0;
            d.vaultBalance += forfeited;
        }

        d.isArbiter[arbiter] = false;
        ArbiterRegistryStorage.clearSeat(d, arbiter);

        // The moment of removal. Since 19 August 2026 this is the SECOND of the
        // two doors to a reply, not the only one: respondToRemoval also admits a
        // caller under a live proposal. This mark covers the half "he has
        // already been removed, the proposal is gone (clearSeat took it away a
        // few lines above) — and he is still entitled to speak". Without it
        // someone who stayed silent during the pause would lose his word at
        // exactly the moment he needed it.
        //
        // The boundary "a stranger does not answer a non-existent accusation" is
        // now held by both halves together: zero here AND no live proposal.
        // Guarded by test_StrangerWithNoAccusationStillCannotAnswer.
        d.removedAt[arbiter] = block.timestamp;

        // The evidence is spent — see the docstring above.
        d.arbiterMistakeStreak[arbiter] = 0;

        d.suspendedUntil[arbiter] = block.timestamp + ArbiterRegistryStorage.SUSPENSION_WINDOW;

        uint256 len = d.arbiterList.length;
        for (uint256 i = 0; i < len; i++) {
            if (d.arbiterList[i] == arbiter) {
                d.arbiterList[i] = d.arbiterList[len - 1];
                d.arbiterList.pop();
                break;
            }
        }
    }

    /// Anyone may press this, and that is the point: the chain laid the
    /// accusation itself, the pause has passed, and there is nothing left to
    /// judge. Nobody gains the right to DECIDE — only the right to press.
    ///
    /// The alternative, "only the holder of the removal right may press", was
    /// rejected by the owner on 18 August 2026: it turns
    /// the automatic path into a reminder. Three overturns would buy a 72-hour
    /// suspension and a record, and everything after that would hang on whether
    /// one man noticed and pressed within fourteen days. A mechanism that works
    /// only while someone is watching is not a mechanism.
    ///
    /// ONE ARGUMENT, and that is the guarantee: cause, evidence, path and clock
    /// all come out of the record the chain wrote. There is nothing to bend —
    /// no second parameter, no way to press this with a different cause, and no
    /// way to press it against a human accusation at all.
    ///
    /// The presser is not named anywhere. Recording him would invite the ledger
    /// to read him as the accuser, and he merely pressed — the design attaches
    /// no person's name to the chain's accusation. That also settles the gasless
    /// question by degenerating it: there is nothing to sign, so there is
    /// nothing to forward — the project's own relayer may press it like anybody
    /// else.
    ///
    /// ⚠️ THE ORDER OF THE FIRST TWO REFUSALS IS LOAD-BEARING. NotAChainProposal
    /// is raised BEFORE the clock is looked at, so a stranger pressing against a
    /// human accusation learns "not yours to press" and not
    /// RemovalTooEarly(when) — which would tell him an accusation stands and
    /// when it ripens. The same disclosure is guarded on proposeRemoval
    /// (test_StrangerLearnsNothingAboutALiveProposal); swapping these two lines
    /// reopens it here, and
    /// test_TheButtonRefusesTheWrongDoorBeforeItMentionsTheClock goes red.
    function executeChainRemoval(address arbiter) external {
        if (arbiter == address(0)) revert ArbiterZeroAddress();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.RemovalProposal storage p = d.removalProposals[arbiter];

        uint256 proposedAt = p.proposedAt;
        if (proposedAt == 0) revert NoLiveProposal();
        if (p.by != address(0)) revert NotAChainProposal();

        // The same window as the common door, read the same way and in the same
        // order: not before REMOVAL_DELAY, not on or after PROPOSAL_TTL. Diverge
        // from hasLiveProposal on either bound and the button goes dark while
        // the feed still shows the accusation as live.
        if (block.timestamp < proposedAt + REMOVAL_DELAY) {
            revert RemovalTooEarly(proposedAt + REMOVAL_DELAY);
        }
        if (block.timestamp >= _proposalDeadline(p)) revert ProposalStale(proposedAt);

        if (!d.isArbiter[arbiter]) revert NotAnArbiter();

        // ⚠️ THE CAUSE IS **NOT** RE-PROVED HERE, AND THAT IS THE DECISION
        // (owner, 18 August 2026). The record the
        // chain laid IS the proof: the chain wrote it at the moment the facts
        // happened, in its own name, having checked them itself. Asking the
        // counter again two days later means asking a different question — "is
        // it still true today" — and the answer to that can be bought.
        //
        // Measured, not imagined: _requireProven reads arbiterMistakeStreak,
        // and finalizeVerdict ZEROES that counter on a clean verdict. So an
        // arbiter the chain had already charged could sit out the suspension,
        // take any dispute, carry it through cleanly, and the button would
        // answer CauseNotProven. The charge did not die with it — it hung for
        // the full PROPOSAL_TTL, barring resignAsArbiter — so he ended up
        // neither removed nor free, which is the worse of the two outcomes for
        // everybody. Owner's words: "doing something and then getting away with
        // it does not fly — prove you did not do it".
        //
        // ⚠️ WHAT DOES CANCEL A CHAIN ACCUSATION — exactly four things, and
        // good behaviour afterwards is not among them. This list is the answer
        // to the question someone will ask in a month:
        //
        //   1. a panel vindicating the arbiter — resolveAppeal quenches the
        //      accusation, zeroes the streak and lifts the suspension, because
        //      the panel said the mistake was not a mistake.
        //      It quenches a LIVE accusation only: a stale one is dead already,
        //      and touching it would take back a whole streak instead of the
        //      one mistake the panel withdrew;
        //   2. withdrawProposal, by the removal authority or the chief — whose
        //      name then stands in the feed next to the withdrawal. ⚠️ BOTH of
        //      those shrink to one at the handover: withdrawProposal refuses
        //      everyone but the successor once governance is active and a
        //      successor is named (19 August 2026). Written there as its own
        //      branch, deliberately — leaning on _requireOwnerOrChief for this
        //      would NOT have done it, because that predicate gates the chief
        //      and lets the owner through always, which is exactly the hole
        //      that was measured;
        //   3. PROPOSAL_TTL running out — fourteen days in which nobody, out of
        //      everyone alive, thought it worth pressing;
        //   4. this very function, executing it.
        //
        // Each of the four is either a finding that the charge was WRONG, or a
        // decision by someone who can be named. Working well afterwards is
        // neither, and it never touches the record.
        Cause cause = Cause(p.cause);

        // Read BEFORE the removal: clearSeat erases both the proposal and the
        // saved path as part of one tidy-up.
        uint8 path = d.chainProposalPath[arbiter];

        // The forfeited bond is not carried into any log on this path, exactly
        // as it was not before: ArbiterDemoted has no amount field, and
        // widening it would change a signature the live subgraph matches by its
        // canonical form. The vault balance moves, and getVaultBalance shows it.
        _performRemoval(d, arbiter);

        // The permanent half of the record, and the reason
        // chainProposalPath exists at all: the standing card must still tell
        // the three automatic paths apart — 253 overturn, 254 timeout, 255
        // appeal — now that the unseating happens two days after the path was
        // known (that distinction was built into the card on purpose).
        ArbiterRegistryStorage.recordAutomaticRemoval(d, arbiter, path);

        // ⚠️ ArbiterDemoted FIRES HERE AND NOT AT THE THIRD MISTAKE. It says
        // "this arbiter is demoted", and until this line he is not: he is
        // suspended and accused. The live subgraph reads it as an exit — it
        // sets seated = false and voids the open proposal — so emitting it on
        // the accusation would have marked a seated man gone AND cancelled, in
        // the feed, the very accusation the same transaction laid.
        //
        //   • `by` is the zero address: nobody pressed anything that decided
        //     this, and the presser is deliberately not named.
        //   • `path` is the one saved when it was known.
        //   • `agreement` is the zero address, and honestly so: by now the
        //     cause is a SERIES of mistakes, not one deal. The deal that
        //     tipped him over is named by RemovalProposedByChain, in the
        //     transaction where it was true.
        emit ArbiterRegistryFacet.ArbiterDemoted(
            arbiter, address(0), ArbiterRegistryFacet.DemotionPath(path), address(0)
        );

        // Same second record the common door leaves: "accused at X, removed at
        // Y" readable inside one transaction instead of stitched across two
        // logs by arbiter address. `proposedBy` is zero here because the
        // accuser was the chain, and the digest is zero because the evidence
        // was the chain's own state.
        emit RemovalProposalConsumed(arbiter, cause, address(0), bytes32(0), proposedAt);
    }

    // ⚠️ No XP reset happens here: ReputationStorage lives in a different
    // namespace, and pulling it in would create a second write point into
    // someone else's storage — diverging from the single place that writes
    // demotion XP today (_recordArbiterMistake in ArbiterRegistryFacet). The XP
    // of an arbiter removed for cause stays as it is; the divergence from the
    // automatic demotion is deliberate and can be addressed separately, if the
    // owner sees fit.

    // ============================================================
    //  THE RIGHT OF REPLY (15 August 2026)
    //
    //  An accusation against a real address stays on chain forever. The reply
    //  cancels nothing and returns nothing — it exists so that a reader of the
    //  chain sees TWO records instead of one.
    //
    //  ⚠️ Since 19 August 2026 the reply is accepted DURING the pause, not only
    //  after a removal: while a live proposal stands against a person, he is
    //  entitled to put his objection on chain. It moves no clock — the removal
    //  happens at exactly the same second, on top of the objection rather than
    //  instead of it.
    //
    //  The reply slot is about the CURRENT accusation, not about the person for
    //  life. Whoever lays a new accusation clears it (proposeRemoval and
    //  ArbiterRegistryFacet._recordArbiterMistake); whoever takes an accusation
    //  back clears it too (withdrawProposal and the acquittal branch in
    //  ArbiterRegistryFacet.resolveAppeal).
    //
    //  ⚠️ A REMOVAL DOES NOT TOUCH THE SLOT, and that is a requirement rather
    //  than an omission: the sentence lands ON TOP of the objection, not
    //  instead of it (test_AnswerGivenBeforeRemovalSurvivesIt).
    //
    //  ⚠️ AND GOING STALE DOES NOT TOUCH IT EITHER — this used to say "a removal
    //  is the ONLY event that leaves the slot alone", and that was untrue.
    //  Going stale has no code at all: the TTL simply stops being satisfied,
    //  and there is nobody to erase anything. Hence the state "the accusation is
    //  dead while the digest still lies there" — a known open item, and one
    //  cured on the READER's side: the card must ask for the pair "reply +
    //  accusation". The right of reply is not lost by it — the next accusation
    //  clears the slot.
    // ============================================================

    /// ⚠️ The ONLY gasless function of this facet. The sender is taken through
    /// _msgSender(), not msg.sender: the caller is the accused or removed
    /// arbiter — an ordinary person who may hold no ETH. On the path through the
    /// relayer msg.sender is the MinimalForwarder address, and the reply would
    /// be recorded against the forwarder instead of the person.
    ///
    /// ⚠️ `reply` is a RIGHT, not a duty (design of 17 August 2026). An empty
    /// string is legal and produces no event. The digest remains mandatory: the
    /// digest IS the reply, and the words are its summary for the feed.
    /// Admitting a reply without a digest would mean that "a reply" may be a
    /// string with no preimage, and the "already answered" test
    /// (`removalReply != 0`) would stop working.
    function respondToRemoval(bytes32 replyDigest, string calldata reply) external {
        if (replyDigest == bytes32(0)) revert ZeroDigest();
        // The ceiling comes from the shared check rather than being recomputed
        // here: the unit of counting must be the same for accusation and
        // defence. That a copy drifts silently was measured — see
        // _requireWithinCap.
        //
        // There is no mandatoriness here and there must not be: that is exactly
        // why _requireReason is not called from here. An empty reply is legal.
        uint256 len = _requireWithinCap(reply);

        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        // ⚠️ THE ANSWER IS TAKEN DURING THE PAUSE (design of 17 August 2026).
        // This line used to read `removedAt == 0` alone, so the word came AFTER
        // the sentence: the right of reply existed, the adversarial part did
        // not. The pause gave the accused forty-eight hours and nothing he could
        // do in them.
        //
        // TWO DOORS, not one: a LIVE PROPOSAL stands against him (he is still
        // an arbiter, the clock of the pause is running) OR the removal has
        // already happened. The second half is kept deliberately — a removal
        // erases the proposal on its way out through clearSeat, and the man who
        // was silent during the pause must still be able to speak after it.
        //
        // ⚠️ AND THE FIRST HALF IS THE ONLY DOOR THE CHAIN-ACCUSED HAS. Since
        // 18 August 2026 the third judicial mistake SUSPENDS AND ACCUSES instead
        // of unseating, so `removedAt` is never written on that path until
        // somebody presses executeChainRemoval — and nobody is obliged to. He
        // is the one accused by no person, and he is also the only one the
        // accusation stops from working, so for those two days this is
        // literally the only thing he can do on chain.
        //
        // A stale proposal does not let him in: hasLiveProposal compares
        // against PROPOSAL_TTL with the same strictness as the gate in
        // removeArbiterForCause — there is nothing to answer exactly when there
        // is nothing left to execute.
        //
        // The answer does NOT move the clock: there is no write to
        // removalProposals here, and there must never be one.
        if (d.removedAt[caller] == 0 && !hasLiveProposal(caller)) revert NothingToAnswer();
        // "Answered" means answered THE ACCUSATION THAT STANDS NOW, not
        // answered once in a lifetime. Whoever lays a new accusation clears
        // this — proposeRemoval for a person's, _recordArbiterMistake for the
        // chain's — and whoever takes one back clears it too.
        if (d.removalReply[caller] != bytes32(0)) revert AlreadyAnswered();

        d.removalReply[caller] = replyDigest;
        emit RemovalAnswered(caller, replyDigest);
        if (len != 0) {
            emit RemovalReplyGiven(caller, reply);
        }
    }

    function getRemovalReply(address arbiter) external view returns (bytes32) {
        return ArbiterRegistryStorage.data().removalReply[arbiter];
    }

    // -------- THE CHIEF ARBITER'S PROPOSAL (15 August 2026) --------
    //
    // A removal is irreversible: it strips the status, burns the bond and leaves
    // a permanent public accusation on chain against a real address. Something
    // like that must not depend on any one person other than the owner. The
    // chief, meanwhile, watches the corps at closer range than anyone, and
    // forbidding him to signal would be foolish — hence the split: he lays a
    // proposal on chain under HIS OWN address, and the owner agrees under HIS,
    // by calling the ordinary removeArbiterForCause.
    //
    // ⚠️ The link between proposal and execution is CLEANUP plus ONE
    // COMPARISON (design of 17 August 2026). removeArbiterForCause still READS
    // nothing out of removalProposals into the record: the cause code, the
    // digest, the dispute reference and the words are all supplied afresh, by
    // the accuser's own arguments. Taking the proposal on trust and executing
    // it with one button would be the mirror image of the very risk for which
    // the right of removal is withheld from the chief altogether.
    //
    // But since 17 August the proposal is a MANDATORY INPUT: without one there
    // is no removal, and the pause runs from it. Hence the single comparison —
    // the cause code at execution must match the one proposed. Otherwise the
    // warning would be about one thing and the execution about another, and
    // "a word before the sentence" would be a word off the point.
    //
    // The cleanup itself (15 August 2026) lives in
    // ArbiterRegistryStorage.clearSeat — ONE point for every door out of the
    // corps, not only for this one. The rationale is the same as for
    // removeArbiterForCause: a proposal must not outlive the person it stood
    // against.
    //
    // ⚠️ THERE IS NO LIST OF NAMES HERE ANY MORE, AND DELIBERATELY SO. One used
    // to stand here, it went stale and it lied: before 18 August 2026 the third
    // door was named as `_recordArbiterMistake`, and since then that function
    // takes no seat away at all — the third mistake suspends and accuses.
    // Anyone trusting the list would have drawn the OPPOSITE conclusion to the
    // one that change was made for.
    //
    // Instead of a list, a property and a way to check it: `clearSeat` is called
    // only by exit doors, and that is verified with `grep -rn "clearSeat(" src/`.
    // The current roll of callers is kept by the docstring of `clearSeat`
    // itself, in one place, rather than in three copies across two files.
    //
    // A proposal must be checked by the same rules as the removal itself: if the
    // code is one taken on trust (Collusion/Leak/Other), the evidence digest is
    // mandatory already here and not only at execution — otherwise the chief
    // would lay an empty accusation on chain that hangs for two weeks backed by
    // nothing. The verifiable codes (OverturnedVerdicts/Timeouts/Silence) are
    // deliberately NOT checked by the chain at this stage: the fact may appear
    // only after the proposal, and demanding it in advance would forbid warning
    // before the event.

    /// Lay a proposal on chain. One live proposal per arbiter — a single claim,
    /// not a queue. It can be replaced, but NOT by overwriting: the previous one
    /// is withdrawn first (withdrawProposal), and the withdrawal stays in the
    /// feed as RemovalProposalWithdrawn. The analysis is in a separate ⚠️ below.
    ///
    /// ⚠️ The words are mandatory HERE, not only at execution (design of
    /// 17 August 2026, from the pause and the duty-to-explain rule together).
    /// A pause now stands between the proposal and the removal, during which the
    /// accused is entitled to answer. If the words appear only at the moment of
    /// removal, the pause hands the person a numeric cause code and nothing
    /// more — he would be answering a guess.
    ///
    /// ⚠️ Since 17 August 2026 this is the ONLY way in to a removal. The
    /// proposal is no longer "a signal one may skip": without it
    /// removeArbiterForCause reverts NoLiveProposal, and executing it is
    /// possible no earlier than REMOVAL_DELAY and no later than PROPOSAL_TTL
    /// from this very second.
    ///
    /// ⚠️ AND THAT IS WHY THIS DOOR MOVED WITH THE OTHER ONE (17 August 2026).
    /// It used to stand under onlyOwnerOrChief alone, and the named successor
    /// does not fit through that: he is neither the owner nor the chief.
    /// Harmless while the proposal was optional — the successor removed with one
    /// button and needed nobody. The pause made the proposal MANDATORY, and the
    /// handover this whole branch was built for was cancelled by that same
    /// pause: the right had moved, but the successor could not use it until the
    /// FORMER owner laid a proposal for him. A veto by inaction, invisible in
    /// the feed, held by the one person the handover exists to remove from the
    /// loop.
    ///
    /// Rule, the same one the withdrawal door got: whoever may REMOVE may
    /// PROPOSE — plus the chief, for as long as the role of chief exists.
    ///   • before handover: the owner and the chief, exactly as before;
    ///   • after handover: the successor only. The chief needs no separate
    ///     exclusion — live governance abolishes the role inside
    ///     _requireOwnerOrChief — and the owner is pushed out here for the same
    ///     reason removeArbiterForCause pushes him out: the handover is whole
    ///     or it is theatre. A proposal he could still lay would be executable
    ///     by the successor, so keeping it would keep him in the loop by the
    ///     back door.
    ///
    /// Taken from _removalAuthority, not written in its own words: a second
    /// expression meaning "the same thing" is the seam this branch has already
    /// dug out three times — the duplicated suspension window, the removal right
    /// that had to become transferable in two places at once, and the
    /// measurement that justified
    /// test_AfterHandoverTheSuccessorWithdrawsAnyProposal.
    ///
    /// ⚠️ ONE LIVE PROPOSAL PER PERSON, AND IT HOLDS THE DOOR. This used to
    /// overwrite whatever stood there — anyone's record, silently, resetting the
    /// 48-hour clock with it. That is exactly the power denied to the chief on
    /// withdrawProposal, walking back in
    /// one door over: measured on the live diamond, the chief could keep the
    /// owner's accusation from ever ripening (RemovalTooEarly on every attempt
    /// to execute), do it to an accusation against HIMSELF, swap the cause out
    /// from under a removal already in flight (CauseDiffersFromProposal), and
    /// hold the arbiter's bond hostage on the way — resignAsArbiter is barred
    /// while a proposal is live, and the proposal renewed forever.
    ///
    /// Now the record is cleared by an explicit withdrawProposal, which leaves
    /// RemovalProposalWithdrawn in the feed. Nobody is locked out: the
    /// authority may withdraw anyone's, so two transactions do everything one
    /// used to — and both are readable. The author of a live proposal gets no
    /// exemption either, because a silent clock reset is the whole finding.
    ///
    /// ⚠️ THE GATE SITS BELOW THE ROLE CHECKS, AND THAT ORDER IS PART OF THE
    /// RULE. ProposalAlreadyLive(by, proposedAt) is
    /// not a plain "no" — it discloses that an accusation stands against this
    /// arbiter and who laid it. A stranger must be refused for his role BEFORE
    /// he learns that, on both role doors: _requireOwnerOrChief before the
    /// handover and RemovalHandedOver after it. Guarded, not merely intended,
    /// by test_StrangerLearnsNothingAboutALiveProposal and
    /// test_StrangerLearnsNothingAboutALiveProposalAfterHandover — moving these
    /// four lines above the role branch turns both red.
    function proposeRemoval(
        address arbiter,
        Cause   cause,
        bytes32 evidenceDigest,
        string calldata reason
    )
        external
    {
        if (arbiter == address(0)) revert ArbiterZeroAddress();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        (address authority, bool handedOver) = _removalAuthority(d);
        if (handedOver) {
            // Same refusal as the sibling door gives in the same state, and
            // for the same reason — the accusation channel travelled with the
            // right to act on it. A stranger gets it here too, exactly as he
            // does from removeArbiterForCause after handover.
            if (msg.sender != authority) revert RemovalHandedOver();
        } else {
            _requireOwnerOrChief(d);
        }

        if (!d.isArbiter[arbiter]) revert NotAnArbiter();

        // ⚠️ A NEW ACCUSATION IS A NEW RIGHT TO ANSWER (a consequence of the
        // design of 17 August 2026).
        //
        // The hole this closes is opened by the "answer during the pause" edit
        // itself: `removalReply` used to be erased ONLY by clearRemovalRecord,
        // and that is called only by the SEATING doors (addArbiter /
        // applyAsArbiter). A seated arbiter who answers a proposal goes through
        // neither — he never left — so his answer would sit in storage forever,
        // and the SECOND, real accusation against him would meet AlreadyAnswered
        // on empty ground. The right of reply would be lost without a single
        // removal.
        //
        // These lines cannot erase an answer to a LIVE removal: proposeRemoval
        // requires isArbiter, and a seated arbiter always has removedAt == 0 —
        // both entry doors clear it, both exit doors take isArbiter away.
        // test_SeatedArbiterNeverCarriesALiveRemoval stands over that pair.
        //
        // ⚠️ This is not the only door an accusation comes through. The chain
        // lays its own past this function, by writing storage directly in
        // ArbiterRegistryFacet._recordArbiterMistake, and the same clearing
        // line stands there for the same reason.
        //
        // The words themselves are not lost: they are in the RemovalReplyGiven
        // log. Storage answers one question only — "did he answer the accusation
        // standing right now" — which is exactly what the docstring of the
        // removalReply field says.
        delete d.removalReply[arbiter];

        // ⚠️ This power was taken away from the chief on withdrawProposal —
        // "stop a removal, and start it over, every time" — and it walked back
        // in through this door: an overwrite resets the clock just as well as a
        // withdrawal did, and leaves nothing in the ledger. Measured, not
        // suspected: the chief killed the owner's accusation indefinitely,
        // including one against himself.
        //
        // Clearing a record now costs an explicit withdrawProposal, which emits
        // RemovalProposalWithdrawn. The authority is never locked out — he may
        // withdraw anyone's — and the author of a live proposal is refused too,
        // on purpose: a silent clock reset is the whole finding.
        //
        // hasLiveProposal, not `proposedAt != 0`: staleness is one rule and it
        // already has a home. A second copy here would be the same class of
        // defect again — two expressions promised to agree, with nothing that
        // goes red when they stop.
        if (hasLiveProposal(arbiter)) {
            ArbiterRegistryStorage.RemovalProposal storage live = d.removalProposals[arbiter];
            revert ProposalAlreadyLive(live.by, live.proposedAt);
        }

        bool verified = _isChainVerifiable(cause);
        if (!verified && evidenceDigest == bytes32(0)) revert EvidenceRequired();
        _requireReason(verified, reason);

        d.removalProposals[arbiter] = ArbiterRegistryStorage.RemovalProposal({
            cause:          uint8(cause),
            evidenceDigest: evidenceDigest,
            proposedAt:     block.timestamp,
            by:             msg.sender,
            // The life of THIS accusation, frozen now. The
            // accused is told "fourteen days" once; shortening the constant
            // afterwards must not take them back from him.
            ttl:            uint64(PROPOSAL_TTL)
        });
        emit RemovalProposed(arbiter, msg.sender, cause, evidenceDigest, block.timestamp);
        if (bytes(reason).length != 0) {
            emit RemovalReasonGiven(arbiter, msg.sender, REASON_STAGE_PROPOSAL, reason);
        }
    }

    /// Withdraw a proposal before it expires — YOUR OWN. The holder of the
    /// removal right may withdraw anyone's.
    ///
    /// ⚠️ THIS USED TO BE "ANYONE'S, BY EITHER OF THE TWO" (17 August 2026,
    /// when the 48-hour pause arrived). Both the owner and the chief walked
    /// under onlyOwnerOrChief and either could clear any record — harmless
    /// while a proposal was only a SIGNAL that took nothing away.
    ///
    /// The pause ended that. A removal now runs ONLY through a proposal that
    /// has sat, so clearing someone else's record is the power to STOP a
    /// removal — and to do it again every time, for as long as the accuser
    /// keeps trying. The chief was deliberately denied the power to remove;
    /// giving him the power to prevent one is no lighter, and it lands on the
    /// exact principle the owner set out: gate what is WEIGHTY, not
    /// everything.
    ///
    /// There is no case where the chief needs to withdraw the owner's
    /// proposal. Someone else's record expires on its own after PROPOSAL_TTL,
    /// and the chief cannot execute it in any event — it just lies there,
    /// harming nobody.
    ///
    /// ⚠️ "The elder" is _removalAuthority, not the owner literally — the same
    /// predicate as the right to remove, not a second condition written in its
    /// own words (the seam this branch already caught twice — see the
    /// docstring of _removalAuthority). Before handover that is the owner;
    /// after it, the named successor. So the successor gains a door that
    /// onlyOwnerOrChief kept shut to him entirely — the same fix liftSuspension
    /// received when the removal right became transferable, and for the same
    /// reason: a door nobody opens is worse than a door at the owner's.
    ///
    /// The modifier is gone from the signature for that reason and that reason
    /// only; the role check itself did not weaken.
    ///
    /// ⚠️ AND SINCE 19 AUGUST 2026 THE DOOR CLOSES AT THE
    /// HANDOVER — read the branch in the body, not this paragraph's older
    /// wording. It used to end "callers who are not the authority still go
    /// through _requireOwnerOrChief, so a stranger still gets NotOwnerOrChief,
    /// and the chief still loses this door once governance is active". That
    /// describes only the state BEFORE the handover now:
    ///
    ///   • before: the authority passes; everyone else through
    ///     _requireOwnerOrChief, so the chief withdraws his own and the chain's,
    ///     a stranger gets NotOwnerOrChief;
    ///   • after: ONLY the successor, and everyone else — the former owner and
    ///     the chief and any stranger alike — gets RemovalHandedOver.
    ///
    /// The reason the branch had to be written here rather than left to
    /// _requireOwnerOrChief: that predicate gates the CHIEF and lets the owner
    /// through always, so leaning on it kept a quiet, unlimited veto with the
    /// man the handover exists to remove from the loop. Measured, not supposed.
    function withdrawProposal(address arbiter) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.RemovalProposal storage p = d.removalProposals[arbiter];

        (address authority, bool handedOver) = _removalAuthority(d);
        // ⚠️ A CHAIN-LAID PROPOSAL HAS NO AUTHOR (18 August 2026).
        // `by` is the zero address there, and the line below — written when
        // every proposal came from a person — would have refused everyone but
        // the authority. The docstring that used to stand here said `by ==
        // address(0)` means "there is no record at all"; since the chain lays
        // its own, that is no longer true, and it was the third comment in this
        // area found to be lying.
        //
        // The owner's decision: BOTH the
        // authority and the chief may stop an accusation the chain laid.
        // Manufactured overturns have to be stoppable by someone, or three
        // presses run to the end with nobody able to intervene. The other side
        // was said out loud and accepted: the chief gains the power to shield
        // his own — but only with his name in the log.
        bool chainLaid = p.proposedAt != 0 && p.by == address(0);

        // ⚠️ AND AFTER THE HANDOVER THIS DOOR BELONGS TO THE SUCCESSOR ALONE
        // (owner's decision, 19 August 2026). The same shape as
        // proposeRemoval a few functions up, and for the same reason.
        //
        // What it fixes was measured, not supposed: `_requireOwnerOrChief` lets
        // the owner through ALWAYS — its DAO gate sits on the chief's branch
        // only — and `chainLaid` skips the NotYourProposal line, so the former
        // owner kept a quiet, unlimited power to cancel the chain's automatic
        // accusations against any arbiter, for as long as the protocol lives.
        // That is precisely the residue the handover ratchet exists to remove,
        // and it was asymmetric on top: the chief already loses this door the
        // moment governance activates.
        //
        // The consequence, said in this door's own voice rather than left to be
        // inferred from a predicate two screens away: once governance is
        // active and a successor is named, NOBODY but the successor withdraws
        // anything here — not the former owner, not the chief. Before that
        // moment nothing changes at all: owner and chief withdraw exactly as
        // they did, which is what test_ChiefMayWithdrawTheChainAccusationHeDidNotLay
        // and its neighbours keep honest.
        if (handedOver) {
            if (msg.sender != authority) revert RemovalHandedOver();
        } else if (msg.sender != authority) {
            _requireOwnerOrChief(d);
            // An empty record still needs no separate branch: `by` is the zero
            // address there too, and `chainLaid` is false because `proposedAt`
            // is zero — so a non-authority calling against nobody's record is
            // refused by this very line, while the authority passes above it
            // and no-ops in silence, which is what the `existed` flag below is
            // about.
            if (!chainLaid && msg.sender != p.by) revert NotYourProposal();
        }

        // The event fires only if a record really stood there — otherwise a call
        // against a person nobody had accused would leave
        // RemovalProposalWithdrawn in the feed, reading as "something stood
        // against him and it was withdrawn". The feed is the whole point of this
        // mechanism; lying to it is not allowed, not even with an empty
        // withdrawal.
        bool existed = p.proposedAt != 0;
        delete d.removalProposals[arbiter];

        // ⚠️ WITHDRAWING THE CHAIN'S ACCUSATION PUTS THE MAN BACK WHOLE, and
        // that means the counter too. Leave the streak standing and he walks
        // away one overturn short of the same accusation being laid again —
        // the withdrawal would buy him a single transaction of relief. The
        // saved path goes with it: it belongs to the record just erased.
        //
        // Only the chain's own. A human accusation withdrawn says nothing about
        // the arbiter's mistakes, and clearing the counter on it would let one
        // proposal-and-withdrawal pair launder a real streak.
        if (chainLaid) {
            delete d.chainProposalPath[arbiter];
            d.arbiterMistakeStreak[arbiter] = 0;
        }

        if (existed) {
            // The accused is owed a CLOSURE, not a silence (design of 17 August
            // 2026). In storage a closure looks like this: nothing stands against him
            // any more, and there is nothing left to answer. The answer itself
            // stays on chain in RemovalAnswered / RemovalReplyGiven — what is
            // erased is not the history but the flag "answered the thing that
            // is hanging right now".
            //
            // ⚠️ INSIDE `if (existed)`, AND THAT PLACEMENT IS THE RULE, not
            // tidiness. withdrawProposal does not require isArbiter, and against
            // a man already removed the record is empty (clearSeat erased it)
            // while his answer is not. An unconditional delete here would hand
            // the accuser a button that wipes the objection of someone he has
            // already unseated. Guarded by
            // test_WithdrawingNothingDoesNotEraseARemovedMansAnswer.
            delete d.removalReply[arbiter];
            emit RemovalProposalWithdrawn(arbiter, msg.sender);
        }
    }

    // -------- VIEWS --------

    function isSuspended(address arbiter) public view returns (bool) {
        return block.timestamp < ArbiterRegistryStorage.data().suspendedUntil[arbiter];
    }

    function getSuspendedUntil(address arbiter) external view returns (uint256) {
        return ArbiterRegistryStorage.data().suspendedUntil[arbiter];
    }

    /// The only public getter for the suspension window, and it stays here after
    /// the constant moved into ArbiterRegistryStorage (16 August 2026): the
    /// facet's selector is untouched and the number is the same.
    function getSuspensionWindow() external pure returns (uint256) {
        return ArbiterRegistryStorage.SUSPENSION_WINDOW;
    }

    /// The MANUAL removal threshold, read from this side. Strictly less than
    /// ArbiterRegistryFacet.getMaxArbiterMistakes() — checked by the test
    /// test_MistakeThresholdMatchesRegistry (equality is forbidden on purpose,
    /// see the docstring of MISTAKE_THRESHOLD).
    function getMistakeThreshold() external pure returns (uint256) {
        return MISTAKE_THRESHOLD;
    }

    /// The mirror of MAX_ARBITER_MISTAKES read from here — the number itself,
    /// not the removal threshold (that is getMistakeThreshold(), one lower). It
    /// exists solely so that test_MistakeThresholdMatchesRegistry can check both
    /// ends of the relation `MISTAKE_THRESHOLD = MAX_ARBITER_MISTAKES − 1`
    /// against the live number in ArbiterRegistryFacet, and not merely against
    /// each other.
    function getMaxArbiterMistakesMirror() external pure returns (uint256) {
        return MAX_ARBITER_MISTAKES_MIRROR;
    }

    /// The mirror of DAO_THRESHOLD read from here. Checked by the test
    /// test_DaoThresholdMatchesRegistry.
    function getDaoThresholdMirror() external pure returns (uint256) {
        return DAO_THRESHOLD_MIRROR;
    }

    /// Whether a proposal is live right now. `proposedAt == 0` means there is no
    /// proposal at all: none was ever laid, or the record was cleared by one of
    /// three routes — `withdrawProposal`, a removal (through `clearSeat`), and,
    /// since 18 August 2026, an acquittal of the arbiter by the panel in
    /// `ArbiterRegistryFacet.resolveAppeal`, which quenches the CHAIN's
    /// accusation entirely. The boundary is strict, as with suspendedUntil: on
    /// the very last second of the TTL it is still live.
    ///
    /// ⚠️ There are several readers, and the list of them is no longer kept
    /// here: it went stale twice already — through edits to other functions
    /// whose diffs never touched this line (`liftSuspension` became a reader on
    /// 18 August 2026, `respondToRemoval` on 19 August). Instead of a list, a
    /// rule: whoever needs the BOOLEAN answer "is a proposal live" calls this
    /// function and does not write the comparison again.
    ///
    /// There are exactly two lawful exceptions TO THAT RULE in this file, and
    /// both compare against the deadline directly because a boolean is not
    /// enough for them: `removeArbiterForCause` and `executeChainRemoval` revert
    /// `ProposalStale(proposedAt)` WITH AN ARGUMENT.
    ///
    /// ⚠️ WHAT TO CHECK CHANGED ON 26 AUGUST 2026. Grepping for `PROPOSAL_TTL`
    /// no longer counts the comparisons: the lifetime moved into the record
    /// itself, and EXACTLY ONE place adds it to `proposedAt` —
    /// `_proposalDeadline` below. The constant remains two things and only two:
    /// the lifetime frozen into a NEW record (`proposeRemoval`), and the
    /// fallback answer for a record with a zero `ttl` written before that
    /// change. Grep for `_proposalDeadline` now: there must be THREE calls — the
    /// two exceptions above and the body of this function.
    ///
    /// The cost of a copy was measured twice, both times on 18 August 2026: the
    /// predicate in `liftSuspension` forgot about the TTL and locked the chief
    /// out forever; the acquittal branch in `resolveAppeal` quenched the counter
    /// on a DEAD accusation.
    function hasLiveProposal(address arbiter) public view returns (bool) {
        ArbiterRegistryStorage.RemovalProposal storage p =
            ArbiterRegistryStorage.data().removalProposals[arbiter];
        if (p.proposedAt == 0) return false;
        return block.timestamp < _proposalDeadline(p);
    }

    /// When THIS accusation runs out — its own moment plus its own life
    /// (26 August 2026).
    ///
    /// ⚠️ THIS IS THE ONLY PLACE IN EITHER FACET THAT ADDS A LIFETIME TO A
    /// `proposedAt`, and that is the point of it existing. Before the record
    /// carried its life, the sum was written out in three places against a
    /// constant; shortening the constant by a cut then expired every standing
    /// accusation AT ONCE, with nobody sending a transaction and the accused
    /// seeing nothing happen. A man told he has fourteen days plans for
    /// fourteen days.
    ///
    /// Zero means the record was written before the field existed, and the
    /// constant in force is exactly the rule it was written under.
    function _proposalDeadline(ArbiterRegistryStorage.RemovalProposal storage p)
        private view returns (uint256)
    {
        uint256 ttl = p.ttl;
        return p.proposedAt + (ttl == 0 ? PROPOSAL_TTL : ttl);
    }

    /// Reading the record whole, archived ones included (stale or already
    /// executed — such a record is still readable from here until it is
    /// overwritten by a new one or deleted). The fifth field, `live` (added
    /// 15 August 2026 and fixed the same day), is a CALL to `hasLiveProposal`
    /// and not a copy of its formula: the answer "is a proposal live" has one
    /// owner, and drifting from the strictness of the comparison or from the
    /// `proposedAt` check is structurally impossible inside this file, not
    /// merely absent because the two texts happen to agree today. Callers used
    /// to be obliged to REMEMBER to call `hasLiveProposal` separately after
    /// reading the docstring — a defence that rests on a person reading a
    /// comment is no defence in this project. A function's selector does not
    /// depend on its return type, so the deployment cascade is untouched.
    function getRemovalProposal(address arbiter)
        external view returns (uint8 cause, bytes32 evidenceDigest, uint256 proposedAt, address by, bool live)
    {
        ArbiterRegistryStorage.RemovalProposal storage p =
            ArbiterRegistryStorage.data().removalProposals[arbiter];
        return (p.cause, p.evidenceDigest, p.proposedAt, p.by, hasLiveProposal(arbiter));
    }

    function getProposalTTL() external pure returns (uint256) {
        return PROPOSAL_TTL;
    }

    /// The pause between a proposal and the removal. Ask the chain rather than
    /// counting at home: a copy of this number in the frontend would drift in
    /// silence and show the button as live an hour before it starts working.
    function getRemovalDelay() external pure returns (uint256) {
        return REMOVAL_DELAY;
    }

    /// The ceiling on words in BYTES. The form must ask the chain for it rather
    /// than keep a number of its own: once the two drift, the person gets a
    /// rejected transaction instead of a hint in the field.
    function getMaxReasonBytes() external pure returns (uint256) {
        return MAX_REASON_BYTES;
    }

    // -------- AN ARBITER'S STANDING IN ONE READ (15 August 2026) --------

    /// The whole standing of an arbiter in a single read. Assembling this on the
    /// frontend from seven or eight separate queries is not acceptable: blocks
    /// pass between them and the picture contradicts itself — the bond read
    /// before the removal, the status after it.
    ///
    /// The set of fields is wider than the original brief (seven there:
    /// xp..openClaims) — while the plan was being written, storage grew things
    /// the brief did not know about:
    ///
    /// `cleanVerdicts` — judicial service (how many verdicts reached
    /// finalisation without being overturned). Without it the card misses the
    /// main thing: this is the number by which manually seated arbiters are to
    /// be converted when the DAO switches on (see the docstring of
    /// ArbiterRegistryStorage.Data.cleanVerdicts).
    ///
    /// `overturnedVerdicts` — THE SECOND HALF OF THE FRACTION (21 August 2026),
    /// and it sits IMMEDIATELY next to the first on purpose. Apart, both numbers
    /// lie: `cleanVerdicts` alone made a patient bad arbiter look better than an
    /// honest newcomer — "mistake, mistake, clean" round and round grows the
    /// service record and never carries the streak to the threshold — while a
    /// bare sum of overturns punishes long service, because someone who has
    /// handled five hundred disputes collects more of them than a bad arbiter
    /// who handled twenty. The READER does the dividing: this pair has no
    /// thresholds and no consequences at all (the owner's decision, on the
    /// ladder "visible → counted").
    ///
    /// `removedAt` — the moment of removal, zero if never removed. The screen
    /// tells a serving arbiter from a removed one by a single field, without
    /// guessing from the others.
    ///
    /// `hasLiveRemovalProposal` — whether a removal proposal by the chief stands
    /// right now. Read by CALLING hasLiveProposal(arbiter) rather than by
    /// copying its staleness formula: exactly such a duplicate was caught and
    /// reworked in this same body of work (getRemovalProposal) — a second place
    /// comparing `proposedAt + PROPOSAL_TTL` against its own notion of "live"
    /// would be a new seam of the same defect class.
    ///
    /// XP and cleanStreak are read from ReputationStorage — someone else's
    /// namespace, by the same technique as _isDaoActive above: this facet
    /// already knows how to reach it.
    ///
    /// `removalCount` / `lastRemovalAt` / `lastRemovalCause` — the removal
    /// history (16 August 2026). It answers a question the other fields cannot:
    /// `removedAt` above speaks only about the CURRENT, not-yet-undone removal
    /// and is zeroed by any reseating — and the reseating is done by the
    /// accuser, and after the DAO switches on by the accused himself. Without
    /// these three fields the card would show a clean man to someone who was
    /// removed three times.
    ///
    /// `lastRemovalCause` is encoded: 0 — never removed, 1..6 — Cause plus one,
    /// 252..255 — automatic demotion (no cause, but the path is named:
    /// AUTO_REMOVAL_BASE + ArbiterRegistryFacet.DemotionPath, that is
    /// 253 — overturned by the owner, 254 — agreement timeout, 255 — votes on an
    /// appeal; 252 means "path not named" and is sent by no caller). The
    /// encoding belongs to ArbiterRegistryStorage, here it is only read.
    ///
    /// Three automatic codes rather than one (16 August 2026): the distinction
    /// between paths was introduced with a dedicated event field, but NOBODY
    /// reads the events — the card is the only place they are read from, and a
    /// single code would lose the distinction exactly where it is needed.
    ///
    /// A function's selector does not depend on its return type — widening the
    /// tuple leaves the deployment cascade alone.
    ///
    /// ⚠️ THIS USED TO SAY "the function has zero readers today (checked by grep
    /// over the web client's source), there is nothing to break" — and it went
    /// stale: since 17 August 2026 it is read by a web client hook dedicated to
    /// this standing tuple, which destructures the tuple BY POSITION. So
    /// inserting a field in the middle must travel together with that hook and
    /// with its own test. It will not pass silently: the arity of the
    /// tuple changes, every destructuring of the old field count stops
    /// compiling, and a web client guard compares the order of the hook's
    /// fields against the order of the returns in the ABI.
    function getArbiterStanding(address arbiter) external view returns (
        uint256 xp,
        uint256 cleanStreak,
        uint256 mistakeStreak,
        uint256 bond,
        address seatedBy,
        uint256 suspendedUntil,
        uint256 openClaims,
        uint256 cleanVerdicts,
        uint256 overturnedVerdicts,
        uint256 removedAt,
        bool    hasLiveRemovalProposal,
        uint256 removalCount,
        uint256 lastRemovalAt,
        uint8   lastRemovalCause
    ) {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ReputationStorage.Data storage rep = ReputationStorage.data();
        return (
            rep.xp[arbiter],
            rep.cleanStreak[arbiter],
            d.arbiterMistakeStreak[arbiter],
            d.arbiterBond[arbiter],
            d.seatedBy[arbiter],
            d.suspendedUntil[arbiter],
            d.openClaimCount[arbiter],
            d.cleanVerdicts[arbiter],
            d.overturnedVerdicts[arbiter],
            d.removedAt[arbiter],
            hasLiveProposal(arbiter),
            d.removalCount[arbiter],
            d.lastRemovalAt[arbiter],
            d.lastRemovalCause[arbiter]
        );
    }

    // ============================================================
    //  READS THAT MOVED HERE FROM ArbiterRegistryFacet (16 August 2026)
    //
    //  ⚠️ THIS IS A MOVE, NOT AN EDIT. The bodies below are byte for byte the
    //  ones that stood in ArbiterRegistryFacet; no behaviour is changed. From
    //  outside the diamond the move is invisible: a caller hits the same proxy
    //  address with the same selector and gets the same answer — only a row in
    //  the internal routing table changes.
    //
    //  WHY THEY MOVED. ArbiterRegistryFacet hit the EIP-170 ceiling:
    //  24 516 bytes of 24 576, 60 free — "the arbiter registry can no longer be
    //  fixed". The neighbouring facet is 18 % full. Both hold ONE namespace
    //  (ArbiterRegistryStorage, the same POSITION), so no data is moved at all
    //  and the storage layout is untouched to the bit.
    //
    //  WHY THESE ONES. The boundary is drawn by meaning: what moved here are
    //  reads about an arbiter's BEHAVIOUR, his STANDING and the EVIDENCE — what
    //  this facet is for (the precedent is getArbiterStanding above, which reads
    //  the same fields). What stayed in the registry is what it owns: the
    //  composition of the corps, disputes, verdicts, appeals and money.
    //
    //  ⚠️ WHAT IS DELIBERATELY ABSENT HERE: getters for the registry's
    //  CONSTANTS (getMinXPToRegister, getNoResponseFloor, getMaxArbiterMistakes,
    //  getMaxClaimsPerArbiter). Those numbers are declared privately in
    //  ArbiterRegistryFacet and applied by the code that stays there; moving a
    //  getter would create a SECOND declaration, so the outside world would be
    //  answered by a mirror while the rule was applied from the original — the
    //  same class of defect analysed in the docstring of _msgSender above. If
    //  those bytes are ever needed, the constant moves into
    //  ArbiterRegistryStorage as ONE declaration serving both facets, as was
    //  already done with SUSPENSION_WINDOW.
    // ============================================================

    // ── An arbiter's behaviour and standing ──

    /// @notice The streak of consecutive judicial mistakes.
    ///
    /// ⚠️ IT READS UP TO AND INCLUDING MAX_ARBITER_MISTAKES (18 August 2026).
    /// This used to say "at the threshold the automatic demotion strips the
    /// status and zeroes the counter, so at rest the value is always strictly
    /// below the threshold" — and that stopped being true in both halves: at the
    /// threshold the chain ACCUSES, and it leaves the counter standing — because
    /// a streak of judicial mistakes did not end merely because the chain
    /// noticed it. (Not "because the chain's own accusation is proven by it":
    /// `executeChainRemoval` does not read the counter at all, see the docstring
    /// of MISTAKE_THRESHOLD.)
    ///
    /// FOUR places zero the counter, and the first of them predates this branch
    /// — review found the list was incomplete by exactly that one:
    ///
    ///   • `ArbiterRegistryFacet.finalizeVerdict` — a clean verdict closes the
    ///     streak. This is NOT a footnote in the list: the decision not to
    ///     re-prove cause in the chain door rests on it, because this is what
    ///     made a re-check inside the button cancellable by good work done after
    ///     the accusation;
    ///   • `ArbiterAccountabilityFacet._performRemoval` — a removal, both doors;
    ///   • `withdrawProposal` — withdrawing the CHAIN's accusation (a human one
    ///     leaves the counter alone);
    ///   • `ArbiterRegistryFacet.resolveAppeal` — an acquittal by the panel (the
    ///     subtraction of one, when there is no chain accusation, lives there
    ///     too).
    ///
    /// The analysis of the two thresholds is in the docstring of
    /// MISTAKE_THRESHOLD.
    ///
    /// ⚠️ THIS IS NOT "HOW MANY TIMES HE WAS WRONG" (21 August 2026). The streak
    /// is zeroed by a clean verdict, so "mistake, mistake, clean" round and
    /// round holds it at two forever, and a reader who takes that zero for a
    /// total will see a good judge where there have been thirteen overturns. The
    /// total is given by getOverturnedVerdicts, and it must be read IN PAIR with
    /// getCleanVerdicts.
    function getArbiterMistakeStreak(address addr) external view returns (uint256) { return ArbiterRegistryStorage.data().arbiterMistakeStreak[addr]; }

    /// @notice How many of this arbiter's verdicts reached finalisation without
    /// being overturned. Groundwork for the future conversion "bond plus
    /// judicial service" when the DAO switches on (15 August 2026) — the
    /// conversion itself is not implemented here, only the counter.
    ///
    /// ⚠️ HALF A FRACTION, NOT A SCORE (21 August 2026). On its own this number
    /// made a patient bad arbiter look BETTER than an honest newcomer:
    /// "mistake, mistake, clean" round and round grows the service record while
    /// the mistake streak never reaches the threshold. The other half is
    /// getOverturnedVerdicts.
    function getCleanVerdicts(address arbiterAddr) external view returns (uint256) {
        return ArbiterRegistryStorage.data().cleanVerdicts[arbiterAddr];
    }

    /// @notice How many of this arbiter's verdicts have been overturned, over
    /// his whole service (21 August 2026).
    ///
    /// ⚠️ READ IT NEXT TO getCleanVerdicts, NEVER ALONE. The two are halves of
    /// one fraction, and the sum on its own punishes long service: twenty
    /// overturns out of five hundred and twenty out of twenty-five are
    /// different men. getArbiterStanding hands both out in one call for exactly
    /// that reason; this getter exists for the caller who already has the other
    /// half.
    ///
    /// ⚠️ NOT THE MISTAKE STREAK. getArbiterMistakeStreak above counts judicial
    /// mistakes IN A ROW and is cleared by every clean verdict — which is how
    /// "mistake, mistake, clean" round and round kept an arbiter's record
    /// looking better than a newcomer's. This one is never cleared by good work
    /// afterwards; a panel that vindicates him takes back exactly one.
    ///
    /// ⚠️ IT GATES NOTHING. No threshold reads it and no door asks it — the
    /// rungs stop at "visible → counted" by the owner's decision of 21 August
    /// 2026. Whoever wires a consequence to it later is making a new decision,
    /// not finishing this one.
    ///
    /// Sits in THIS facet, not the registry, for the reason the fourteen
    /// readings above moved here: the registry is the one that is running out
    /// of room, and readings about an arbiter's BEHAVIOUR are this facet's
    /// business anyway.
    ///
    /// ⚠️ A SNAPSHOT, NOT A STANDING FACT, and the earlier wording here was the
    /// second kind: "the registry has 1 504 bytes of headroom left" went stale
    /// the same week it was written. The number as measured: 1 504 bytes free on
    /// 19 August 2026, 1 207 on 21 August. Today's number comes from
    /// `forge build --sizes` and from nowhere else — not from a docstring in a
    /// public .sol that nothing recomputes.
    function getOverturnedVerdicts(address arbiterAddr) external view returns (uint256) {
        return ArbiterRegistryStorage.data().overturnedVerdicts[arbiterAddr];
    }

    /// @notice The arbiter's bond. Forfeited into the vault on a removal for
    /// cause and on an automatic demotion, returned in full on resignAsArbiter.
    function getArbiterBond(address addr) external view returns (uint256) { return ArbiterRegistryStorage.data().arbiterBond[addr]; }

    /// @notice How many disputes the arbiter holds right now. The ceiling is
    /// ArbiterRegistryFacet.getMaxClaimsPerArbiter().
    function getOpenClaimCount(address addr) external view returns (uint256) { return ArbiterRegistryStorage.data().openClaimCount[addr]; }

    /// @notice The accumulated share of fees the arbiter has not yet collected.
    function getArbiterReward(address arbiter) external view returns (uint256) { return ArbiterRegistryStorage.data().arbiterRewards[arbiter]; }

    /// @notice Service record: the deals whose disputes this arbiter claimed.
    function getArbiterDeals(address arbiter) external view returns (address[] memory) { return ArbiterRegistryStorage.data().arbiterDeals[arbiter]; }

    // ── Seating provenance ──

    /// @notice Who seated this arbiter. `address(0)` means self-enrolment
    /// through applyAsArbiter (a manual seating carries neither a bond nor the
    /// XP gate).
    function getSeatedBy(address arbiter) external view returns (address) {
        return ArbiterRegistryStorage.data().seatedBy[arbiter];
    }

    /// @notice How many arbiters seated by this address are serving right now.
    function getSeatedCountBy(address seater) external view returns (uint256) {
        return ArbiterRegistryStorage.data().seatedCountBy[seater];
    }

    /// @notice How much of an already funded dispute top-up came out of the
    /// arbiter bank (29 August 2026). Zero means the bank put in
    /// nothing — either the discount is off, or the bank was empty when the
    /// top-up was paid, or the dispute has already left and the reservation
    /// went back into `vaultBalance`.
    ///
    /// ⚠️ IT LIVES HERE FOR BYTES, NOT FOR MEANING. The rule that decides the
    /// number is in ArbiterRegistryFacet (`_splitTopUp`), and so is the writer;
    /// this is a bare storage read of a field that facet owns, put in this file
    /// because the registry stands 90 bytes under the EIP-170 ceiling and could
    /// not hold one more function. Same storage, same POSITION, same diamond
    /// address — from outside nothing about it is different.
    ///
    /// No second copy of the discount rule is here and none may be added: what
    /// the bank WOULD take off a top-up that is not yet paid is not answerable
    /// from this file without duplicating that rule, and a second copy of it is
    /// the failure this whole design was written to avoid.
    function getDisputeSubsidy(address agreement) external view returns (uint256) {
        return ArbiterRegistryStorage.data().disputeVaultSubsidy[agreement];
    }

    // ── Evidence: the anchor, silence, digests, keys ──

    /// @notice When the CURRENT claimant took this dispute, in block seconds. If
    /// he took it several times — the moment of the last claim, which is what
    /// the floor is counted from. 0 means the dispute is unclaimed (released
    /// included) or was claimed before the cut that introduced this record.
    ///
    /// The signature takes one argument on purpose: the caller needs the anchor
    /// of whoever is judging the dispute now, not a history per arbiter. The
    /// history exists, in the DisputeClaimed/DisputeReleased events.
    function getDisputeClaimedAt(address agreement) external view returns (uint256) {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        return d.disputeClaimedAtBy[agreement][d.disputeClaims[agreement]];
    }

    /// @notice When the current claimant recorded "asked, no answer". 0 means he
    /// did not. Zero here also means "the dispute belongs to nobody": the record
    /// belongs to the arbiter rather than to the deal, and it goes out of sight
    /// with the claim without disappearing from the chain.
    ///
    /// ⚠️ The floor for this record (NO_RESPONSE_FLOOR, 24 hours) is declared and
    /// applied in ArbiterRegistryFacet — it must be asked for there, through
    /// getNoResponseFloor(). There is deliberately no second declaration here,
    /// see the header of this section.
    function getNoResponseAt(address agreement) external view returns (uint256) {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        return d.disputeNoResponseAtBy[agreement][d.disputeClaims[agreement]];
    }

    /// @notice Every presentation digest for a deal, in the order they appeared.
    /// The order IS the substance of the answer: a dispute is decided by what
    /// was laid down earlier.
    ///
    /// Convenient and honest at ordinary counts, but the whole list at a large
    /// one hits the gas ceiling of eth_call — and what breaks is the read AT THE
    /// ARBITER's end and at the other party's, not at the end of whoever
    /// inflated the list. Anyone who needs a guarantee uses
    /// getPresentationDigestsPage below. Who laid each digest is not visible
    /// here: that is in the PresentationDigestRecorded event, which is also
    /// where the block number comes from.
    function getPresentationDigests(address agreement) external view returns (bytes32[] memory) {
        return ArbiterRegistryStorage.data().presentationDigests[agreement];
    }

    /// @notice A window over a deal's digests: from `offset`, at most `limit` of
    /// them.
    /// @dev The full getPresentationDigests is honest at small counts, but on a
    /// large list it hits the eth_call ceiling — and what breaks is the read AT
    /// THE ARBITER's end, not at the end of whoever inflated the list. The window
    /// gives the reader a way out without a contract upgrade.
    ///
    /// ⚠️ It NEVER reverts on an honest request: the reader is not required to
    /// know the length in advance, and he can learn it only with a second call —
    /// that is, in another block, when the length is already different. A revert
    /// on "offset past the end" would mean the paginator has to win a race
    /// against the writer. Hence:
    ///   - `offset` past the end of the list (and an empty list) → empty array;
    ///   - `limit == 0`                                          → empty array;
    ///   - `offset + limit` greater than the length              → tail to the end.
    /// An empty answer reads unambiguously as "there is nothing more here", and
    /// that is the stop condition for a paginator. Telling it apart from
    /// "overshot" is possible with getPresentationDigestCount, but usually
    /// pointless.
    ///
    /// The sum `offset + limit` is deliberately never computed, and this is not
    /// pedantry: under the checked arithmetic of 0.8 a naive `offset + limit`
    /// with a `limit` such as type(uint256).max PANICS (0x11), which breaks the
    /// exact promise "no revert on an honest request" — and "give me everything
    /// from this point" is an honest request. Measured by mutation: the naive
    /// sum turns test_Page_HugeLimit_IsUpToTheEnd_NotARevert red with panic
    /// 0x11.
    function getPresentationDigestsPage(address agreement, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        bytes32[] storage all = ArbiterRegistryStorage.data().presentationDigests[agreement];
        uint256 len = all.length;
        if (offset >= len) return new bytes32[](0);

        uint256 available = len - offset;
        uint256 n = limit < available ? limit : available;

        bytes32[] memory page = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            page[i] = all[offset + i];
        }
        return page;
    }

    /// @notice How many digests a deal holds. Separate from the list so that a
    /// screen that only needs "any or none" does not drag the whole array.
    function getPresentationDigestCount(address agreement) external view returns (uint256) {
        return ArbiterRegistryStorage.data().presentationDigests[agreement].length;
    }

    /// The public halves of an arbiter's chat keys. Zeros mean "no keys" — for
    /// the presentation flow that reads as "there is nobody to present to", and
    /// telling "no record" apart from "a zero was recorded" is pointless: a zero
    /// key is rejected on write.
    ///
    /// ⚠️ The converse does not hold: a non-zero key does NOT mean "a serving
    /// arbiter". The key is not erased when the status is lost
    /// (removeArbiterForCause/resignAsArbiter/demotion) — see the warning in
    /// setArbiterChatKey. The status is read separately, through
    /// ArbiterRegistryFacet.isRegisteredArbiter, and not inferred from the
    /// presence of a key.
    function getArbiterChatKeys(address arbiter)
        external
        view
        returns (bytes32 boxKey, bytes32 signKey)
    {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        return (d.arbiterBoxKey[arbiter], d.arbiterSignKey[arbiter]);
    }
}
