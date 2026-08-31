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
// DAO mode: ONLY after owner.activateDAO() — which does not go through before
//   uniqueActiveUsers >= DAO_THRESHOLD (10 000) and the successor has confirmed
//   itself. From then on users with XP >= 3000 may join through applyAsArbiter().
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
        /// 1..6 — the Cause code plus one, 252..255 — auto-demotion (there is no
        /// cause at all, but the path is named: AUTO_REMOVAL_BASE + DemotionPath).
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
        /// `getArbiterFloor()` two functions apart in this file. The cost of
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
    /// removal has exactly three paths, and ArbiterRegistryFacet.DemotionPath
    /// already tells them apart — but only in the event feed, that is, exactly
    /// where nobody reads. The getArbiterStanding card is the only readable
    /// place, and one shared code would lose in it a distinction that was
    /// introduced there on purpose.
    ///
    /// Encoding: `AUTO_REMOVAL_BASE + uint8(DemotionPath)`, that is
    ///   252 — Unspecified (the path is not named; no caller sends it),
    ///   253 — OwnerOverturn, 254 — AgreementTimeout, 255 — AppealVote.
    /// The base is 252 and not 255 because the enum holds four values and the
    /// top end of uint8 must stay reachable without overflow. A new path has to
    /// be seated BELOW the base (or the base moves) — and that is good: a fifth
    /// one cannot be added silently.
    uint8 internal constant AUTO_REMOVAL_BASE = 252;

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
        delete d.removedAt[arbiterAddr];
        delete d.removalReply[arbiterAddr];
        if (liftSuspension) delete d.suspendedUntil[arbiterAddr];
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
    /// ⚠️ CHOSEN BY JUDGEMENT, NOT BY MEASUREMENT: there is no data on
    /// decentralised labour exchanges, here or in the open. The anchor is
    /// Farcaster at some 55 000 in its best moments — a well funded, widely
    /// known protocol, half of the threshold carried here before.
    ///
    /// ⚠️ `Treasury.DAO_THRESHOLD` IS A SEPARATE CONSTANT AND STILL SAYS
    /// 100 000. The treasury is deployed and immutable; its number changes only
    /// by deploying another treasury, which is not this work. The two are meant
    /// to agree by design, so the live treasury's copy is a KNOWN
    /// DISAGREEMENT until that deploy, not an oversight.
    uint256 private constant DAO_THRESHOLD      = 10_000;    // uniqueActiveUsers — condition for switching on by hand
    uint256 private constant MIN_XP_TO_REGISTER = 3_000;     // ~30 deals with different people
    uint256 private constant OVERTURN_XP_SLASH  = 200;       // XP penalty on an overturn
    // DEFAULT_REWARD (5 USDC) was deleted on 31 July: no call read it, while the
    // comment above it called it "the floor of the formula" — even though the real
    // floor of an arbiter's payout is DEFAULT_ARBITER_FLOOR below. Two constants
    // sharing one word in their description, one of them dead, are a false trail
    // and not documentation.
    uint256 private constant FINALIZE_DELAY      = 24 hours;  // window for owner/DAO/appeal before finalization (was 1 hour — not enough for an ordinary user)

    // Floor under a no-response record: this much must pass from the CLAIM of a
    // dispute before the arbiter may write "asked, no answer". Owner's decision of
    // 14.08.2026. Matches FINALIZE_DELAY on purpose: one familiar number, not two.
    //
    // ⚠️ This is the ONLY place the number is declared. The frontend must read it
    // through getNoResponseFloor() rather than keep a copy of its own.
    uint256 private constant NO_RESPONSE_FLOOR = 24 hours;

    uint256 private constant MIN_CLEAN_STREAK_TO_REGISTER = 10;   // the same streak that keeps an executor's XP above 1000
    /// Mistakes in a row before THE CHAIN ACCUSES (not before a removal —
    /// 18 August 2026). At this number `_recordArbiterMistake` suspends the
    /// arbiter and lays a removal proposal in the chain's name; the removal
    /// itself goes through the common door after `REMOVAL_DELAY`. Not to be
    /// confused with ArbiterAccountabilityFacet.MISTAKE_THRESHOLD (2) — that
    /// one is how a PERSON proves a cause, and it is one lower on purpose.
    uint256 private constant MAX_ARBITER_MISTAKES         = 3;
    uint256 private constant DEMOTION_XP_RESET            = 2500; // a fixed reset on removal — not a subtraction
    uint256 private constant ARBITER_BOND                 = 50_000_000; // 50 USDC (6 decimals) — forfeited on demotion, returned on resignAsArbiter()

    uint256 private constant APPEAL_REVIEW_WINDOW = 4 days;     // the same span DISPUTE_WINDOW gives the arbiter
    uint256 private constant APPEAL_MIN_VOTES     = 3;          // quorum of other arbiters
    uint256 private constant APPEAL_DEPOSIT       = 20_000_000; // 20 USDC (6 decimals) — flat, NOT a % of the deal amount

    /// How many votes DECIDE an appeal when turnout is exactly the quorum
    /// (16 August 2026).
    ///
    /// resolveAppeal settles the matter by a simple majority of the votes CAST
    /// as soon as APPEAL_MIN_VOTES of them exist, and anyone may call it. With
    /// three cast, two decide — so the guarded property "the chief does not
    /// decide an appeal" requires a block of STRICTLY FEWER THAN two, not fewer
    /// than three as the earlier version of the cap assumed.
    ///
    /// DERIVED from the quorum rather than written as a number: two values
    /// about one rule would drift apart silently — the same class as
    /// MISTAKE_THRESHOLD in ArbiterAccountabilityFacet, declared as a
    /// subtraction rather than a literal. The quorum does NOT change: 3 stays 3.
    uint256 private constant APPEAL_DECIDING_VOTES = APPEAL_MIN_VOTES / 2 + 1;

    uint256 private constant ARBITER_SHARE_BPS = 8_000; // 80% of the fee to the arbiter, the rest to the treasury

    uint256 private constant DEFAULT_ARBITER_FLOOR = 10_000_000; // 10 USDC (6 decimals)

    /// Starting size of the vault's discount on a dispute top-up.
    /// Only the default: the live number is `disputeVaultDiscount` in storage
    /// and moves with `setDisputeDiscount`.
    uint256 private constant DEFAULT_DISPUTE_DISCOUNT = 3_000_000; // 3 USDC

    // ── Cap on disputes held at once ──
    /// How many disputes an arbiter holds at once. It limits fee farming — an
    /// arbiter earns a share of the fee on EVERY dispute regardless of which
    /// way he ruled, so "grab many and rule at random" is income without
    /// work. The cap counts the NUMBER, not the amount: the amount is set by
    /// whoever created the deal, so a cap on it inherits an untrusted number.
    /// Approved by the owner on 15 August 2026.
    uint256 private constant MAX_CLAIMS_PER_ARBITER = 10;

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
    enum DemotionPath { Unspecified, OwnerOverturn, AgreementTimeout, AppealVote }

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

    /// The panel found the arbiter right, so the chain takes its own accusation
    /// back (18 August 2026). Proposal erased, streak
    /// zeroed, suspension lifted — one record, because the three happen
    /// together and mean one thing.
    ///
    /// A separate event rather than RemovalProposalWithdrawn: that one names
    /// `by` and it is always a person: a zero there would read as "withdrawn
    /// by nobody" and the feed would be guessing which of the two happened.
    /// Only the CHAIN's accusation is ever cleared this way — a human's stands
    /// until its author or the authority withdraws it.
    event ChainAccusationCleared(address indexed arbiter, address indexed agreement);

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
    event DisputeReleased(address indexed agreement, address indexed prevArbiter);
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
    event VerdictFrozen(address indexed agreement);
    event VerdictUnfrozen(address indexed agreement);
    event VerdictOverturned(address indexed agreement, address indexed arbiter, bool newClientWins);
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
    error AlreadyClaimed();
    error NotClaimed();
    error NotDisputed();
    error NotAuthorized();
    error CommitmentNotFound();
    error CommitmentTooEarly();
    error CommitmentExpired();
    error DAONotActive();
    error ZeroChatKey();
    error InsufficientXP(uint256 have, uint256 need);
    error NoVerdict();
    error DisputeWindowPassed();
    error NotLosingParty();
    error AlreadyAppealed();
    error AppealWindowClosed();
    error InsufficientArbitersForAppeal();
    error NoAppeal();
    error AlreadyVoted();
    error CannotVoteOnOwnVerdict();
    error AppealAlreadyResolved();
    error AppealWindowNotClosed();
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
    error ChiefBlocWouldDecideAppeal(uint256 bloc, uint256 decidingVotes);

    // ── Cap on disputes held at once ──
    error TooManyOpenClaims(uint256 held, uint256 cap);

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

    // ── Handover of the corps to governance (15 August 2026): the owner's
    // decision verbatim — "no hand-seated ones", "the person must step out and
    // only the diamond stays, admitting people through the gate" ──
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
    error ReseatingRemovedIsOwnerOnly();

    // -------- MODIFIERS --------

    modifier onlyOwner() {
        if (OwnershipLib.contractOwner() != msg.sender) revert NotOwner();
        _;
    }

    /// ⚠️ THE CHIEF CEASES TO EXIST WHILE GOVERNANCE IS ACTIVE (16 August 2026).
    /// The other half of the same change is in
    /// ArbiterAccountabilityFacet.onlyOwnerOrChief, where the reason is set out
    /// in full: setChiefArbiter is the only writer of d.chiefArbiter and the only
    /// way to zero it, and it was closed under active governance. Without this
    /// line, "the chief is abolished" would mean "the chief becomes
    /// irremovable".
    ///
    /// Both halves must change together: the chief's rights are spread over two
    /// facets (here — addArbiter, there — suspension and the removal proposal),
    /// and one half shut without the other would be worth nothing.
    modifier onlyOwnerOrChief() {
        if (msg.sender != OwnershipLib.contractOwner()) {
            if (isDaoActive() || msg.sender != ArbiterRegistryStorage.data().chiefArbiter)
                revert NotOwnerOrChief();
        }
        _;
    }

    modifier onlyOwnerOrDAO() {
        address dao = ArbiterRegistryStorage.data().daoAddress;
        if (msg.sender != OwnershipLib.contractOwner() && msg.sender != dao)
            revert NotOwnerOrDAO();
        _;
    }

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
    function activateDAO() external onlyOwner {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (d.daoAddress == address(0)) revert DaoAddressNotSet();
        uint256 users = ReputationStorage.data().uniqueActiveUsers;
        if (users < DAO_THRESHOLD) revert DaoThresholdNotReached(users, DAO_THRESHOLD);
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

    function applyAsArbiter() external {
        if (!isDaoActive()) revert DAONotActive();

        address caller = _msgSender();
        ReputationStorage.Data storage rep = ReputationStorage.data();
        uint256 xp = rep.xp[caller];
        if (xp < MIN_XP_TO_REGISTER) revert InsufficientXP(xp, MIN_XP_TO_REGISTER);
        uint256 streak = rep.cleanStreak[caller];
        if (streak < MIN_CLEAN_STREAK_TO_REGISTER) revert InsufficientCleanStreak(streak, MIN_CLEAN_STREAK_TO_REGISTER);

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        if (d.isArbiter[caller]) revert AlreadyArbiter();

        address usdc = FactoryStorage.store().usdc;
        bool bondOk = IUSDCFull(usdc).transferFrom(caller, address(this), ARBITER_BOND);
        require(bondOk, "ArbiterRegistry: bond transfer failed");
        d.arbiterBond[caller] = ARBITER_BOND;

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

        uint256 bond = d.arbiterBond[caller];
        d.arbiterBond[caller] = 0;
        if (bond > 0) {
            address usdc = FactoryStorage.store().usdc;
            bool ok = IUSDCFull(usdc).transfer(caller, bond);
            require(ok, "ArbiterRegistry: bond refund failed");
        }

        ArbiterRegistryStorage.clearSeat(d, caller);

        emit ArbiterResigned(caller, bond);
    }

    // -------- ADMIN: MANAGE ARBITERS --------

    /// The chief's role is abolished together with governance activation (the
    /// owner's decision verbatim, 15 August 2026: "no hand-seated ones", "the
    /// person must step out and only the diamond stays, admitting people through
    /// the gate"). A ratchet: isDaoActive() is irreversible, and after the
    /// handover nobody at all can appoint a new chief.
    ///
    /// ⚠️ THE PREDICATE HERE IS THE ABOLITION OF THE ROLE, NOT THE HANDOVER OF
    /// SEATING (16 August 2026). It is NOT the same condition as in
    /// addArbiter, and the two drifted apart on live state:
    ///
    ///   • the chief's role is ABOLISHED when `isDaoActive()` — that is how both
    ///     `onlyOwnerOrChief` modifiers work (here and in
    ///     ArbiterAccountabilityFacet): under live governance they do not see a
    ///     chief at all, and none of his rights remain;
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

    /// Entry into the arbiter corps under live governance is only through
    /// applyAsArbiter (self-registration past the XP/cleanStreak/bond gate). The
    /// owner's decision verbatim, 15 August 2026: "no hand-seated ones" —
    /// neither the owner nor the chief seats arbiters once governance is on.
    ///
    /// ⚠️ On `&& d.daoAddress != address(0)` — see _requireSeatingNotHandedOver.
    ///
    /// ⚠️ RE-SEATING A REMOVED ARBITER IS THE OWNER'S ALONE (16 August 2026).
    /// This function is a second door to the same result that is locked in
    /// `ArbiterAccountabilityFacet.liftSuspension`: `clearRemovalRecord` below
    /// erases the removal window along with the record of it. The full argument
    /// is at the declaration of ReseatingRemovedIsOwnerOnly above.
    function addArbiter(address arbiter) external onlyOwnerOrChief {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        _requireSeatingNotHandedOver(d);
        if (d.isArbiter[arbiter]) revert AlreadyArbiter();

        // The cap applies to the chief only. The owner is not limited: he is the
        // one who decides the composition, and limiting him by this rule would
        // limit his own ability to dilute the chief's bloc.
        //
        // Counted from the DECIDING MAJORITY rather than from the quorum
        // (16 August 2026): at a turnout of exactly the quorum an appeal is
        // decided by two votes out of three, hence bloc ≤ 1.
        if (msg.sender != OwnershipLib.contractOwner()) {
            // Undoing a removal mirrors a removal, and it is not his to do. The
            // discriminator is the same ERASABLE `removedAt` as on the
            // liftSuspension gate: zero for a voluntary leaver and for a newcomer.
            if (d.removedAt[arbiter] != 0) revert ReseatingRemovedIsOwnerOnly();

            uint256 blocAfter = _chiefBloc(d) + 1;
            if (blocAfter >= APPEAL_DECIDING_VOTES) {
                revert ChiefBlocWouldDecideAppeal(blocAfter, APPEAL_DECIDING_VOTES);
            }
        }

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

        // The cap is checked before the staticcalls into Agreement: a refusal
        // must be cheap, not four reads of a foreign contract deep.
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
        require(statusOk, "ArbiterRegistry: failed to read status");
        uint8 agreementStatus = abi.decode(statusData, (uint8));
        if (agreementStatus != 4) revert NotDisputed();

        // Claiming after the verdict window is not allowed. submitVerdict would
        // refuse anyway (DisputeWindowPassed), so a late claim cannot lead to a
        // verdict — but it does set arbiter in the Agreement and thereby cancels
        // the even split of the pot on timeout. Without this check a party with
        // a friendly arbiter would take the whole pot, having proved nothing.
        (bool dOk, bytes memory dData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        require(dOk, "ArbiterRegistry: disputedAt read failed");
        (bool wOk, bytes memory wData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        require(wOk, "ArbiterRegistry: DISPUTE_WINDOW read failed");
        if (block.timestamp > abi.decode(dData, (uint256)) + abi.decode(wData, (uint256))) {
            revert DisputeWindowPassed();
        }

        // An arbiter cannot be a party to the dispute
        (bool clientOk, bytes memory clientData) = agreement.staticcall(abi.encodeWithSignature("client()"));
        (bool execOk,   bytes memory execData)   = agreement.staticcall(abi.encodeWithSignature("executor()"));
        require(clientOk && execOk, "ArbiterRegistry: failed to read parties");
        address agreementClient   = abi.decode(clientData,  (address));
        address agreementExecutor = abi.decode(execData,    (address));
        require(caller != agreementClient && caller != agreementExecutor, "ArbiterRegistry: arbiter is party");

        // The Diamond becomes the arbiter in the Agreement — that is what lets it control the verdict
        (bool setOk,) = agreement.call(
            abi.encodeWithSignature("setArbiter(address)", address(this))
        );
        require(setOk, "ArbiterRegistry: setArbiter failed");

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
        require(dOk, "ArbiterRegistry: disputedAt read failed");
        (bool wOk, bytes memory wData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        require(wOk, "ArbiterRegistry: DISPUTE_WINDOW read failed");
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

        (bool ok,) = agreement.call(
            abi.encodeWithSignature("setArbiter(address)", address(0))
        );
        require(ok, "ArbiterRegistry: reset arbiter failed");

        emit DisputeReleased(agreement, current);
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
        if (d.pendingVerdicts[agreement].submittedAt != 0) revert VerdictAlreadySubmitted();

        // Check that the agreement is still in dispute
        (bool ok, bytes memory st) = agreement.staticcall(abi.encodeWithSignature("status()"));
        require(ok, "ArbiterRegistry: status read failed");
        require(abi.decode(st, (uint8)) == 4, "ArbiterRegistry: not disputed");

        // The arbiter must submit the verdict within DISPUTE_WINDOW of disputedAt. This
        // check used to live in Agreement.resolveDispute() and fired at EXECUTION time —
        // because of FINALIZE_DELAY and appeals, execution legitimately happens long after
        // submission, so the only place where time may be checked is submission.
        (bool disputedOk, bytes memory disputedData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        require(disputedOk, "ArbiterRegistry: disputedAt read failed");
        uint256 disputedAt = abi.decode(disputedData, (uint256));

        (bool windowOk, bytes memory windowData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        require(windowOk, "ArbiterRegistry: DISPUTE_WINDOW read failed");
        uint256 disputeWindow = abi.decode(windowData, (uint256));

        if (block.timestamp > disputedAt + disputeWindow) revert DisputeWindowPassed();

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
            appealDeposit:  0
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
        if (v.frozen) revert VerdictFrozenError();
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
                // An overturned verdict is not paid for: on an overturn 80% of
                // the fee already goes to the treasury (creditDisputeFee), and the
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

        // The verdict reached finalization without an overturn — the judicial mistake
        // was not confirmed, so the mistake streak resets. The judging record grows
        // at the same time (15 August 2026): a counter of unoverturned finalized
        // verdicts, needed for the future "bond plus record" conversion once governance is live.
        if (!v.overturned) {
            d.arbiterMistakeStreak[v.arbiter] = 0;
            d.cleanVerdicts[v.arbiter]++;
        }

        emit VerdictFinalized(agreement, v.arbiter, v.clientWins);
    }

    /// @notice Owner or DAO overturn a verdict before finalization.
    /// The arbiter loses XP and the reward. The new verdict is executed instead of the old.
    ///
    /// ONE VERDICT EARNS AT MOST ONE JUDICIAL MISTAKE — and that promise is
    /// kept by two lines, not by this one. Here: a verdict already overturned,
    /// by this door or by the appeal vote, refuses with AlreadyOverturned.
    /// There in resolveAppeal: a panel that overturns a verdict the hand had
    /// already overturned books nothing, and takes the hand's booking back.
    ///
    /// There is no changing one's mind after the press, and none is needed:
    /// the mind is made up inside the call, through `newClientWins`. Letting
    /// the hand press twice would let the owner walk a dispute's outcome back
    /// and forth without limit, and "whoever pressed last decided" is a worse
    /// property than not being able to reconsider.
    ///
    /// ⚠️ No check of MERIT lives on this door — not one. The whole restraint
    /// on it is arithmetic — three mistakes, and since 18 August 2026
    /// they buy an ACCUSATION plus a 48-hour pause rather than an unseating —
    /// plus the appeal, which stays open after a press here precisely so that
    /// it can contradict it. That pause is what makes the arithmetic worth
    /// something: pressing this three times used to end the matter in one
    /// transaction, past the door that demands a cause, and it survived the
    /// handover because this function admits the owner always.
    function overturnVerdict(address agreement, bool newClientWins) external onlyOwnerOrDAO {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (v.submittedAt == 0) revert NoVerdict();
        if (v.finalized) revert AlreadyFinalized();
        if (v.appealed && !v.appealResolved) revert AppealInProgress();
        // ⚠️ resolveAppeal sets this flag too, so a verdict already reversed by
        // the vote can no longer be reversed again by hand — deliberately: one
        // verdict earns at most one judicial mistake, whoever books it.
        //
        // This line alone did NOT deliver that. The reverse order — hand first,
        // panel second — stayed open, had to stay open (the appeal is the only
        // check on this door), and booked the second mistake there instead.
        // That half is closed inside resolveAppeal, not here.
        //
        // Stands BELOW the three checks above, and that is load-bearing: both
        // `finalized` and an appeal in flight are reachable with `overturned`
        // already true, and in both the older reason is the larger fact and
        // must be the one the person reads.
        if (v.overturned) revert AlreadyOverturned();

        // ⚠️ AN OVERTURN MUST OVERTURN (found in review, 21 August
        // 2026). This door used to accept ANY `newClientWins`, including the
        // value the arbiter had already ruled — a press that changed no
        // outcome, cost the arbiter XP and a judicial mistake, and set
        // `overturned` to true.
        //
        // That flag is what resolveAppeal reads to tell "the panel is
        // vindicating him" from "the panel is overturning him". It asks whether
        // A HAND HAS PRESSED, never whether the outcome now differs from the
        // arbiter's ruling — so after an empty press the two cases became
        // indistinguishable, and the WRONG one was picked: a panel that then
        // voted for the OPPOSITE of the arbiter's ruling — saying plainly that
        // he was wrong — was read as a vindication. Measured by the reviewer:
        // streak 0, overturns 0, and if the empty press was the third mistake,
        // the chain's own accusation and the suspension were quashed with it.
        //
        // So the record could be laundered on purpose: press into the same
        // value, wait for a panel to disagree with the arbiter, walk out clean.
        //
        // `v.clientWins` is the arbiter's OWN ruling at this line, and that is
        // structural rather than incidental: submitVerdict writes it, and the
        // only two other writers (this line below and resolveAppeal) both set
        // `overturned`, which the check above has just excluded.
        //
        // The fix belongs HERE and not in resolveAppeal: an empty overturn is
        // not a real state to be interpreted more carefully later, it is a
        // press that should never have been recorded. Refusing it keeps
        // "overturned == the outcome differs from what the arbiter ruled" true
        // AT EVERY POINT WHERE THAT FLAG IS READ, which is what every reader of
        // it already assumes.
        //
        // ⚠️ Said with the bound rather than without it: the
        // implication is NOT an invariant of the field for all time. The
        // vindication branch of resolveAppeal deliberately ends with
        // `overturned` true and `clientWins` back at the arbiter's own value —
        // a state this very line refuses to create. It reads the flag BEFORE
        // making it, which is what keeps the two compatible, and the bound is
        // what makes the sentence true instead of nearly true.
        //
        // Stands BELOW the four checks above for the same reason they are
        // ordered as they are: "the door is shut" is the larger fact, and an
        // empty press at a finalized verdict must read AlreadyFinalized. Pinned
        // by test_OneVerdictCannotBeOverturnedThreeTimes, which asks for
        // AlreadyOverturned on a press that is ALSO empty.
        if (newClientWins == v.clientWins) revert VerdictUnchanged();

        address slashedArbiter = v.arbiter;
        v.clientWins = newClientWins;
        v.overturned = true;
        v.frozen     = false; // unfrozen so that it can be finalized

        // Slash the arbiter's XP
        ReputationStorage.Data storage rep = ReputationStorage.data();
        _slashArbiterXP(rep, slashedArbiter);

        // `by` is the RAW msg.sender, and that is no oversight: the role on this
        // door was checked by onlyOwnerOrDAO against the same value. Taking
        // _msgSender() here would write one person into the permanent feed while
        // attributing the decision to another (a documented exception to the
        // ERC-2771 sender-check build gate).
        _recordArbiterMistake(d, rep, slashedArbiter, msg.sender, DemotionPath.OwnerOverturn, agreement);

        emit VerdictOverturned(agreement, slashedArbiter, newClientWins);
    }

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
        return paid == 0 ? APPEAL_DEPOSIT : paid;
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
    function _causeForPath(DemotionPath path) private pure returns (uint8) {
        return path == DemotionPath.AgreementTimeout
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
    /// On the MAX_ARBITER_MISTAKES-th mistake in a row: XP hard-reset to
    /// DEMOTION_XP_RESET (a landing point, not a subtraction), suspension for
    /// SUSPENSION_WINDOW, and a removal proposal opened in the CHAIN'S OWN
    /// NAME. The seat is NOT taken here any more — see the branch below.
    /// cleanStreak (the executor streak) is untouched: judging and delivering
    /// are different skills.
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
            // The seat is no longer taken here. The automatic path stops the
            // arbiter at once and ACCUSES him; the removal itself runs through
            // the common door — proposal, 48 hours, a right to answer — like
            // every other removal. Owner's decision of 18 August 2026: "the
            // same door, and the suspension is the fast path".
            //
            // Before this, the quiet door also survived the handover:
            // overturnVerdict sits under onlyOwnerOrDAO, which lets the owner
            // through always, so the ratchet this whole branch exists to build
            // was bypassed by three presses.
            rep.xp[arbiterAddr] = DEMOTION_XP_RESET;

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
                    ttl:            uint64(PROPOSAL_TTL_MIRROR)
                });
                d.chainProposalPath[arbiterAddr] = uint8(path);
                emit RemovalProposedByChain(arbiterAddr, uint8(path), agreement, block.timestamp);
            }
        }
    }

    /// @notice Freeze a verdict (for instance while an investigation runs).
    function freezeVerdict(address agreement) external onlyOwnerOrDAO {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];
        if (v.submittedAt == 0) revert NoVerdict();
        if (v.finalized) revert AlreadyFinalized();
        v.frozen = true;
        emit VerdictFrozen(agreement);
    }

    /// @notice Unfreeze a verdict.
    function unfreezeVerdict(address agreement) external onlyOwnerOrDAO {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];
        if (v.appealed && !v.appealResolved) revert AppealInProgress();
        v.frozen = false;
        emit VerdictUnfrozen(agreement);
    }

    // -------- APPEAL FLOW (user-initiated, pre-finalization only) --------

    /// @notice The losing party challenges a verdict before the money reaches executor/client.
    /// Requires APPEAL_DEPOSIT — flat, not a % of the deal amount (the amount is chosen by the
    /// parties and cannot be trusted as input to anything that can be won or lost).
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
        require(clientOk && execOk, "ArbiterRegistry: failed to read parties");
        address agreementClient   = abi.decode(clientData, (address));
        address agreementExecutor = abi.decode(execData,   (address));

        bool callerIsLosingClient   = caller == agreementClient   && !v.clientWins;
        bool callerIsLosingExecutor = caller == agreementExecutor &&  v.clientWins;
        if (!callerIsLosingClient && !callerIsLosingExecutor) revert NotLosingParty();

        uint256 eligibleVoters;
        uint256 len = d.arbiterList.length;
        for (uint256 i = 0; i < len; i++) {
            if (d.arbiterList[i] != v.arbiter) eligibleVoters++;
        }
        if (eligibleVoters < APPEAL_MIN_VOTES) revert InsufficientArbitersForAppeal();

        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transferFrom(caller, address(this), APPEAL_DEPOSIT);
        require(ok, "ArbiterRegistry: deposit transfer failed");

        v.appealed       = true;
        v.frozen         = true;
        v.appellant      = caller;
        v.appealDeadline = block.timestamp + APPEAL_REVIEW_WINDOW;
        // The money he put down, written next to the appeal it belongs to.
        // Not for reading back the constant — for paying back
        // THIS man. See PendingVerdict.appealDeposit.
        v.appealDeposit  = APPEAL_DEPOSIT;

        emit AppealRaised(agreement, caller);
    }

    /// @notice Any registered arbiter except the one who ruled votes exactly once.
    function voteOnAppeal(address agreement, bool overturn) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (!d.isArbiter[caller]) revert NotArbiter();
        if (!v.appealed) revert NoAppeal();
        if (v.appealResolved) revert AppealAlreadyResolved();
        if (caller == v.arbiter) revert CannotVoteOnOwnVerdict();
        if (block.timestamp >= v.appealDeadline) revert AppealWindowClosed();
        if (d.hasVotedAppeal[agreement][caller]) revert AlreadyVoted();

        d.hasVotedAppeal[agreement][caller] = true;
        if (overturn) {
            v.votesOverturn++;
        } else {
            v.votesUphold++;
        }

        emit AppealVoteCast(agreement, caller, overturn);
    }

    /// @notice Settles the appeal vote. It may be called as soon as the quorum
    /// (APPEAL_MIN_VOTES) is reached, without waiting for the window to end. If the window
    /// closes without a quorum, the appeal is rejected by default (nothing hangs forever).
    function resolveAppeal(address agreement) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (!v.appealed) revert NoAppeal();
        if (v.appealResolved) revert AppealAlreadyResolved();

        bool quorumReached = v.votesUphold + v.votesOverturn >= APPEAL_MIN_VOTES;
        bool windowClosed  = block.timestamp >= v.appealDeadline;
        if (!quorumReached && !windowClosed) revert AppealWindowNotClosed();

        v.appealResolved = true;
        v.frozen         = false;

        bool overturn = quorumReached && v.votesOverturn > v.votesUphold;
        address usdc  = FactoryStorage.store().usdc;

        if (overturn) {
            address slashedArbiter = v.arbiter;

            // ⚠️ READ BEFORE THE WRITE BELOW (found in review,
            // 18 August 2026). At this point `overturned` is true if and only
            // if a HAND already overturned this verdict: overturnVerdict and
            // this branch are its only writers, and this branch runs at most
            // once per verdict (appealResolved). That is why telling the two
            // cases apart needs no new storage field and the layout does not
            // move.
            //
            // ⚠️ AND THE STEP THIS FLAG IS ASKED TO TAKE — "a hand pressed,
            // therefore the standing outcome is NOT the arbiter's ruling,
            // therefore flipping it back vindicates him" — WAS UNSOUND UNTIL
            // 21 August 2026, when it was found in review. overturnVerdict took
            // any value, including the arbiter's own, so an empty press set
            // this flag while the outcome still matched his ruling. The panel
            // then flipping it produced the OPPOSITE of his ruling, and this
            // branch read the panel's disagreement as an acquittal: streak and
            // overturns wound back, and the chain's own accusation quashed.
            //
            // The premise is now enforced where it belongs — overturnVerdict
            // refuses with VerdictUnchanged. Nothing in this branch had to
            // change; what changed is that its premise became true.
            //
            // ⚠️ AND THE CLAIM IS BOUNDED TO THIS LINE, deliberately (review
            // round 2, 21 August 2026, where the earlier wording was found
            // stronger than the truth). What holds is: AT THIS READ, `true`
            // implies the standing outcome differs from the arbiter's ruling.
            // It is NOT a property of the field in general — three lines below,
            // this branch itself flips `clientWins` back to the arbiter's own
            // value and leaves `overturned` true, which is exactly the state
            // the guard forbids elsewhere. That is correct and is the whole
            // point of a vindication; it is also why the flag must be READ
            // BEFORE the write, and why "by construction" without "here" would
            // be a false statement in a public repository heading into audit.
            //
            // The bound holds because only two writers exist and both are
            // excluded above: overturnVerdict cannot leave the flag set on a
            // matching outcome (VerdictUnchanged), and this branch runs at most
            // once per verdict (appealResolved), so its own later write cannot
            // reach this read.
            bool alreadyOverturned = v.overturned;

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
            if (alreadyOverturned) {
                // ⚠️ AND IT REACHES THE CUMULATIVE COUNT TOO, BY ONE
                // (21 August 2026). The panel has just restored this arbiter's
                // own ruling, so his verdict was not overturned in the end and
                // a mark in `overturnedVerdicts` for this dispute would be the
                // record lying — the same argument that made the streak give
                // one back, and the same one that stopped the second booking.
                //
                // ONE, never the whole count, and never zero: the branch below
                // wipes the STREAK entirely when it withdraws the chain's own
                // accusation, but that wipe is about not leaving a vindicated
                // man one overturn away from being accused again. This number
                // opens no door and can borrow no such reason — overturns on
                // OTHER disputes stay his.
                //
                // ⚠️ THE FLOOR, AND WHAT IT IS AND IS NOT FOR — corrected in
                // review, where the first wording overstated the path.
                //
                // It is NOT reachable after the cut: every +1 here has a
                // strictly earlier +1 behind it, and nothing zeroes this field
                // — not removal, not withdrawal, not resignation, not
                // re-seating. The migration window it was written for is
                // narrower still: a verdict overturned BEFORE the cut and
                // appealed AFTER needs raiseAppeal, which needs three voters
                // besides the one who ruled — four arbiters — and the chain has
                // ONE.
                //
                // The guard stays because the cost of being wrong is not a
                // revert: unguarded, 0 − 1 wraps to 2²⁵⁶−1 and stands in a
                // permanent record as the count of this arbiter's overturned
                // verdicts. Guarded by
                // test_VindicationCannotUnderflowTheOverturnCount.
                //
                // ⚠️ AND THE WINDOW HAS A SECOND, LIVELIER SHAPE, named rather
                // than papered over: the count is per ARBITER, not per dispute.
                // Overturn A before the cut (uncounted), overturn B after it
                // (counted, total 1), then A's appeal vindicates him — and the
                // one taken back is B's. A number he earned pays for one the
                // chain never recorded. Same four-arbiter precondition, so it
                // is shut for the same reason today; it is written down because
                // seating three more arbiters opens both without touching a
                // line of code. Left as a known and deliberately unfixed gap.
                uint256 overturns = d.overturnedVerdicts[slashedArbiter];
                if (overturns > 0) d.overturnedVerdicts[slashedArbiter] = overturns - 1;

                // ⚠️ VINDICATION MUST REACH THE CHAIN'S OWN ACCUSATION, not
                // just the counter (18 August 2026) — and the reason is now
                // STRONGER than the arithmetic first written here, because
                // executeChainRemoval stopped re-proving the cause at all.
                //
                // The old wording argued by numbers: the streak sits at 3, the
                // proof threshold is 2, so decrementing to 2 leaves the charge
                // "still provable". That is no longer how the button decides.
                // executeChainRemoval consults the RECORD and nothing else, so
                // the charge would survive the panel's verdict at ANY value of
                // the counter — decrementing it, zeroing it, none of it would
                // matter. Forty-eight hours later a passer-by presses, and the
                // very man the panel found right loses his seat. The button is
                // nobody's on purpose, so there would be no one to ask.
                //
                // Which is why the record itself has to go, and why this branch
                // is not a nicety: it is the only thing standing between a
                // vindication and a removal for the thing vindicated.
                //
                // He cannot even step aside: resignAsArbiter is barred by the
                // suspension AND by the live proposal, and withdrawing that
                // proposal belongs to the owner and the chief alone — otherwise
                // he waits out PROPOSAL_TTL, fourteen days.
                //
                // So the chain withdraws what the chain laid: proposal erased,
                // streak zeroed (same argument as withdrawal — a vindicated
                // arbiter must not stand one overturn away from being accused
                // again), suspension lifted.
                //
                // ⚠️ ONLY THE CHAIN'S OWN. A human accusation (`by` non-zero)
                // is untouched here: a panel deciding one dispute says nothing
                // about a collusion charge somebody else laid, and quashing it
                // would hand every accused arbiter a way to clear his record by
                // appealing an unrelated verdict.
                //
                // ⚠️ Known cost, named rather than papered over: the
                // suspension carries no provenance. If a chief suspended this
                // person for an unrelated reason AFTER the automatic path
                // fired, that suspension is lifted here too. Telling the two
                // apart needs a field the layout does not have, and leaving a
                // vindicated arbiter frozen was judged the worse of the two.
                // ⚠️ `_hasLiveProposalHere`, NOT `proposedAt != 0`
                // (18 August 2026). The same defect as one door over, and it
                // was measured here too: a DEAD accusation, stale for a
                // fortnight and executable by nobody, wiped a streak of 3 down
                // to 0 in one go — flatly against the paragraph seven lines
                // above, which promises that ONE is subtracted — and announced
                // ChainAccusationCleared about a record that had stopped
                // meaning anything long before. Staleness has a home in this
                // file; every predicate that asks about a proposal goes through
                // it.
                if (_hasLiveProposalHere(d, slashedArbiter)
                    && d.removalProposals[slashedArbiter].by == address(0)) {
                    delete d.removalProposals[slashedArbiter];
                    delete d.chainProposalPath[slashedArbiter];
                    // The accusation is gone, so the flag "answered the thing
                    // standing right now" has nothing left to point at
                    // (19 August 2026). Left behind, it would show a reader an
                    // answer to an accusation the panel took back, and it would
                    // meet the arbiter as AlreadyAnswered on the next one. The
                    // words stay in the log, as everywhere else.
                    delete d.removalReply[slashedArbiter];
                    d.arbiterMistakeStreak[slashedArbiter] = 0;
                    d.suspendedUntil[slashedArbiter]       = 0;
                    emit ChainAccusationCleared(slashedArbiter, agreement);
                    // ⚠️ AND THE LIFT IS ANNOUNCED, not done in silence (found
                    // in review, 18 August 2026). Every other way a suspension ends
                    // says so — liftSuspension emits, and the 72 hours running
                    // out is visible because the deadline was in the log when it
                    // was set. This one erased the deadline instead, so a reader
                    // saw a suspension that never ended.
                    //
                    // `by` is the zero address: the panel decided, and no hand
                    // pressed anything here — same reading as everywhere else in
                    // these two facets.
                    //
                    // ⚠️ Known cost, named rather than papered over: the
                    // suspension carries no provenance, so a chief's later,
                    // unrelated suspension of the same person is lifted here
                    // too. Reviewed on 18 August 2026 and the field was
                    // REFUSED: every cheap discriminator produces false
                    // refusals, and a false refusal is the dearer mistake —
                    // it leaves a vindicated man locked in, while the chief who
                    // loses his mark simply sets it again. The log is what
                    // makes that bearable: he can see it happened.
                    emit ArbiterAccountabilityFacet.ArbiterSuspensionLifted(
                        slashedArbiter, address(0)
                    );
                } else {
                    // ⚠️ Underflow is reachable, not theoretical, and since
                    // 18 August 2026 the way in is exact: the accusation the third
                    // mistake laid was EXECUTED while this appeal was in
                    // flight, and _performRemoval zeroed the streak on the way
                    // out. raiseAppeal never asks whether the arbiter is still
                    // seated, so the vote lands on a counter with nothing left
                    // to take back. Withdrawal of the accusation reaches the
                    // same state by a different road. Guarded by
                    // test_VindicationAfterDemotionDoesNotUnderflowTheStreak.
                    uint256 streak = d.arbiterMistakeStreak[slashedArbiter];
                    if (streak > 0) d.arbiterMistakeStreak[slashedArbiter] = streak - 1;
                }
            } else {
                ReputationStorage.Data storage rep = ReputationStorage.data();
                _slashArbiterXP(rep, slashedArbiter);
                // `by` is zero: anyone may call resolveAppeal, and the VOTES decide.
                // Naming whoever pressed "settle" as the author would be the worst
                // of the three possible untruths.
                _recordArbiterMistake(d, rep, slashedArbiter, address(0), DemotionPath.AppealVote, agreement);
            }

            // Outside the branch: the appellant won the vote and gets his
            // deposit back whether or not this verdict had already been
            // overturned by hand. The deposit is the price of asking, not part
            // of the arbiter's penalty.
            // Soft, and for a heavier reason than in clearDisputeClaim. The two
            // writes above are what unfreeze the verdict; a reverting refund
            // takes them down with it, and every other door out is already shut
            // (finalizeVerdict: VerdictFrozenError, unfreezeVerdict and
            // overturnVerdict: AppealInProgress, raiseAppeal: AlreadyAppealed,
            // Agreement.triggerArbiterTimeout: VerdictInFlight, forever, because
            // hasSubmittedVerdict never goes back to false). A $20 deposit that
            // cannot be delivered would therefore strand the WHOLE escrow, in
            // the clone, where no rescue function exists — and it would strand
            // it for the man who WON the appeal. Into the existing claimable, so
            // this costs no storage field and no new selector.
            uint256 deposit = _depositOf(v);
            if (!_softTransfer(usdc, v.appellant, deposit)) {
                d.refundableBounty[v.appellant] += deposit;
                emit DisputeBountyRefundable(agreement, v.appellant, deposit);
            }
        } else {
            // Forfeit reads the same record for the same reason: what the vault
            // keeps is what came in, not what the constant says today.
            d.vaultBalance += _depositOf(v);
        }

        emit AppealResolved(agreement, v.appellant, overturn);
    }

    // -------- REWARDS --------

    /// @notice The arbiter withdraws the reward that has piled up.
    function withdrawArbiterReward() external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        uint256 amount = d.arbiterRewards[caller];
        if (amount == 0) revert NoRewardToClaim();

        d.arbiterRewards[caller] = 0;

        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transfer(caller, amount);
        require(ok, "ArbiterRegistry: USDC transfer failed");

        emit ArbiterRewardWithdrawn(caller, amount);
    }

    /// @notice Credit the dispute fee. The agreement (Agreement.resolveDispute) calls
    /// this function BEFORE transferring `total` to the diamond and transfers only if
    /// the call did not revert — so a failed credit never leaves money on the diamond
    /// with no counter pointing at it (see Agreement.resolveDispute).
    ///
    /// Why the diamond does not pull the money itself through transferFrom: the
    /// agreement would then have to grant an allowance, and on a failed call that
    /// allowance would stay hanging — exactly the defect that had to be fixed in the
    /// treasury. A push transfer (the Agreement calls transfer() itself, the diamond
    /// pulls nothing through transferFrom) leaves no allowance at all — independent of
    /// which comes first, the credit or the transfer (today the credit does, see above).
    ///
    /// The trust here is exactly that of updateStatus and notifyArbiterTimeout: the
    /// caller must be a registered agreement, and registering one is possible
    /// only for the factory.
    ///
    /// There is NO arbiter-address argument (and accepting one would not be right):
    /// claimDispute() always sets the diamond itself as the arbiter IN THE AGREEMENT
    /// (setArbiter(address(this)), Diamond-as-arbiter), so Agreement.arbiter
    /// is always either 0 or the diamond's address, never a person. Accepting it as
    /// a parameter would mean burning 80% of every fee on an arbiter who has no way
    /// to call withdrawArbiterReward() in his own name (that one reads _msgSender(),
    /// and there is nothing that could make the diamond call itself).
    ///
    /// The source of the real arbiter is pendingVerdicts[msg.sender].arbiter, NOT
    /// disputeClaims[msg.sender]. Both fields are written in step (submitVerdict
    /// requires caller == disputeClaims[agreement]) and cannot diverge before
    /// finalization — but at the moment the Agreement actually calls this function
    /// (from inside finalizeVerdict → agreement.call(resolveDispute)), the guarantee
    /// on pendingVerdicts is stronger: finalizeVerdict already requires
    /// v.submittedAt != 0 (otherwise revert NoVerdict before the call) and holds
    /// v.executing = true for the whole external call — it is executing==true that
    /// stops clearDisputeClaim() deleting pendingVerdicts inside that window (this is
    /// not the only place able to delete the record — clearStuckVerdict does the same
    /// WITHOUT checking !v.executing; its gate
    /// require(status != DISPUTED) is by itself no protection here — resolvedAt
    /// is already set by this point (`Agreement.resolveDispute`, before the call), so
    /// status() inside that window would already return RESOLVED rather than DISPUTED,
    /// and the gate would LET IT THROUGH. Wedging in is impossible for another reason:
    /// the whole window — from resolvedAt to this call — lies inside one atomic
    /// transaction (finalizeVerdict → agreement.call(resolveDispute) →
    /// creditDisputeFee), while clearStuckVerdict is a separate call from the owner,
    /// which has nowhere to execute between the steps of another transaction).
    /// disputeClaims has no such protection: clearDisputeClaim() clears it
    /// unconditionally, so its integrity here would depend on the Agreement
    /// transferring the fee and calling in strictly before _clearDisputeClaim() —
    /// that is, on the order of code in another function, not an invariant here.
    /// pendingVerdicts.arbiter never depends on that order under any arrangement.
    function creditDisputeFee(uint256 total) external {
        if (RegistryStorage.store().agreements[msg.sender].client == address(0))
            revert NotRegisteredAgreement();
        if (total == 0) revert ZeroAmount();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[msg.sender];

        address arbiter_ = v.arbiter;
        // Nobody carried the dispute through to a verdict (submitVerdict was never
        // called) — there is nobody to credit, and staying silent is not an option:
        // money with no addressee would hang in the contract with no counter on it.
        if (arbiter_ == address(0)) revert NoVerdictSubmitted();

        uint256 toArbiter;
        uint256 toTreasury;
        if (v.overturned) {
            // The verdict was overturned (overturnVerdict/resolveAppeal) — the
            // arbiter was wrong, there is no reward, the whole fee goes to the
            // treasury. Symmetrical with finalizeVerdict, which on an overturn
            // withholds the top-up too and returns it to the payer through
            // refundableBounty (see the top-up refund block inside finalizeVerdict,
            // earlier in this file). The earlier reference here pointed at the
            // vault payout per dispute, which went away with the flat payout.
            toTreasury = total;
        } else {
            toArbiter = (total * ARBITER_SHARE_BPS) / 10_000;
            // By subtraction rather than a second share: that way no unit is lost
            // to rounding and the parts always add back up to the whole.
            toTreasury = total - toArbiter;
        }

        d.arbiterRewards[arbiter_] += toArbiter;
        d.treasurySlice            += toTreasury;

        emit DisputeFeeCredited(arbiter_, toArbiter, toTreasury);
    }

    /// @notice Send the accumulated treasury slice to the current fee recipient.
    ///
    /// Open on purpose: the money goes only to the address in
    /// FactoryStorage.feeRecipient, so the right to call decides nothing, while
    /// being open means the payout does not depend on the owner remembering it,
    /// and a keeper can push it through.
    function withdrawTreasurySlice() external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        uint256 slice = d.treasurySlice;
        if (slice == 0) revert NothingToPush();

        d.treasurySlice = 0;

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        address recipient = fs.feeRecipient;
        bool ok = IUSDCFull(fs.usdc).transfer(recipient, slice);
        require(ok, "ArbiterRegistry: treasury slice transfer failed");

        emit TreasurySlicePushed(recipient, slice);
    }

    function getTreasurySlice() external view returns (uint256) {
        return ArbiterRegistryStorage.data().treasurySlice;
    }

    /// @notice Top up the arbiter vault. Besides the owner, this can be done by
    /// the current fee recipient (`FactoryStorage.feeRecipient`) — which becomes
    /// the treasury once it is installed by a `setFeeRecipient` call.
    ///
    /// There is deliberately no separate field for the treasury address: one
    /// source of truth, and replacing the treasury carries this right over on its
    /// own, with nothing to forget. If the fee recipient is an ordinary wallet (as
    /// it was before the treasury), it may put its own money in. A donation, not a risk.
    function fundVault(uint256 amount) external {
        if (msg.sender != OwnershipLib.contractOwner()
            && msg.sender != FactoryStorage.store().feeRecipient) revert NotOwnerOrFeeRecipient();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transferFrom(msg.sender, address(this), amount);
        require(ok, "ArbiterRegistry: USDC transfer failed");
        d.vaultBalance += amount;
        emit VaultFunded(msg.sender, amount);
    }

    /// @notice Disabled on 31 July 2026. The flat payout from the vault was
    /// rejected by the design of 28 July (§7), but the code did not follow: the
    /// accrual lived in parallel with the 80% of the fee and was switched on by a
    /// single owner call. With the top-up added, there would be three sources.
    ///
    /// The function is not deleted but reverts: eight historical scripts in
    /// script/ reference its selector in their mounting lists, forge build
    /// compiles the whole folder, and deleting it would break the build. Those
    /// scripts are records of upgrades that happened, and broadcast/ is
    /// gitignored, so their sources are the only remaining record. A reverting
    /// setter is more honest than a working one that writes a value nobody reads.
    function setRewardPerDispute(uint256) external pure {
        revert RewardPathRetired();
    }

    /// @notice How much the arbiter must receive for a dispute in total.
    /// A stored field rather than a constant: the right price of human time
    /// cannot be guessed in advance, and changing it later must cost one
    /// transaction, not an upgrade. It starts at 10 USDC.
    function setArbiterFloor(uint256 amount) external onlyOwner {
        ArbiterRegistryStorage.data().arbiterFloor = amount;
        emit ArbiterFloorUpdated(amount);
    }

    /// @notice How much the arbiter vault takes off a dispute top-up.
    /// Stored, like the floor above, and for a stronger reason: the protocol
    /// has never seen a dispute, so three dollars is a starting point and not
    /// a conclusion. Changing it must cost one transaction, not a cut.
    ///
    /// Takes effect on the NEXT `fundDispute` only. Disputes already funded
    /// keep the split they were funded with — both halves of it are in
    /// storage, so nothing recomputes behind anyone's back.
    function setDisputeDiscount(uint256 amount) external onlyOwner {
        ArbiterRegistryStorage.data().disputeVaultDiscount = amount;
        emit DisputeDiscountUpdated(amount);
    }

    // -------- PAID ARBITER CALL: PAYMENT AND REFUND --------

    /// @notice Top up to the threshold so that an arbiter takes the dispute on.
    ///
    /// No separate "call an arbiter" mechanism is needed: the voluntary claim
    /// already works, it simply does not fire on a small pot. Money on the table
    /// is the only thing it lacks.
    ///
    /// The party that needs a judge pays, not the shared vault. That is the
    /// protection against farming: planting one's own arbiter means paying oneself.
    ///
    /// The sender is taken through _msgSender() and not msg.sender: the web
    /// client calls this function ONLY through the ERC-2771 forwarder, and on
    /// that path msg.sender is the forwarder's address. With a raw msg.sender
    /// the party check would reject
    /// every payment, and the payer in storage and in the event would be the forwarder.
    function fundDispute(address agreement) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        RegistryStorage.AgreementRecord storage rec = RegistryStorage.store().agreements[agreement];
        if (rec.client == address(0)) revert NotAuthorized();
        if (caller != rec.client && caller != rec.executor) revert NotParty();

        if (d.disputeClaims[agreement] != address(0)) revert DisputeAlreadyClaimed();
        if (d.disputeBounty[agreement] != 0) revert BountyAlreadyFunded();

        // gross is the whole top-up to the floor, subsidy is the vault's share of
        // it. Both come from one place, the same one the screen reads.
        (uint256 gross, uint256 subsidy) = _splitTopUp(agreement); // reverts NotDisputed

        // The same gate as in claimDispute (the DisputeWindowPassed check after
        // disputedAt()/DISPUTE_WINDOW()), and the same comparison:
        // after disputedAt + DISPUTE_WINDOW a dispute can neither be claimed nor
        // judged (submitVerdict also raises DisputeWindowPassed), and the status
        // stays DISPUTED until somebody pulls the timeout. Taking money for a
        // judge who can no longer physically exist is not allowed: it would not
        // be lost (it comes back on the timeout) but would freeze until somebody
        // else acts, while the service is never rendered at all.
        (bool dOk, bytes memory dData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        require(dOk, "ArbiterRegistry: disputedAt read failed");
        (bool wOk, bytes memory wData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        require(wOk, "ArbiterRegistry: DISPUTE_WINDOW read failed");
        if (block.timestamp > abi.decode(dData, (uint256)) + abi.decode(wData, (uint256))) {
            revert DisputeWindowPassed();
        }

        // gross is read, not what the person pays: a top-up is needed whenever
        // the arbiter falls short of the floor, regardless of how much of it the
        // vault took on. Checking the person's share would shut this door exactly
        // where the vault pays everything.
        if (gross == 0) revert TopUpNotNeeded();

        d.disputeBounty[agreement]      = gross;
        d.disputeBountyPayer[agreement] = caller;

        // ⚠️ RESERVED HERE, rather than checked at payout. Days pass between the
        // promise and the payout: without a reservation two disputes would be
        // promised the same three dollars, and the second arbiter would come up
        // short at payout — receiving less than the floor through arithmetic here.
        // Subtracting from the vault on this line makes such a shortfall
        // impossible by construction: the money is no longer in the vault.
        if (subsidy != 0) {
            d.vaultBalance -= subsidy;
            d.disputeVaultSubsidy[agreement] = subsidy;
        }

        address usdc = FactoryStorage.store().usdc;
        // Only his own half is taken from the person. There is nowhere and no
        // need to transfer the vault's half: its USDC has sat on the diamond since
        // fundVault, and only the record of whose it is has changed.
        bool ok = IUSDCFull(usdc).transferFrom(caller, address(this), gross - subsidy);
        require(ok, "ArbiterRegistry: bounty transfer failed");

        emit DisputeBountyFunded(agreement, caller, gross - subsidy, subsidy);
    }

    function getDisputeBounty(address agreement) external view returns (uint256) {
        return ArbiterRegistryStorage.data().disputeBounty[agreement];
    }

    /// @notice Collect a top-up that a push refund failed to deliver.
    /// It exists because of USDC blacklists: the refund inside clearDisputeClaim
    /// is deliberately soft, since that path is wrapped in a swallowing catch.
    ///
    /// _msgSender() and not msg.sender, for the same reason as in fundDispute:
    /// the call arrives through the forwarder, and with a raw msg.sender a person
    /// would collect not his own balance but the forwarder's (always zero) one.
    function withdrawDisputeBounty() external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        uint256 amount = d.refundableBounty[caller];
        if (amount == 0) revert NoRefundableBounty();
        d.refundableBounty[caller] = 0;
        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transfer(caller, amount);
        require(ok, "ArbiterRegistry: bounty withdrawal failed");
        emit DisputeBountyWithdrawn(caller, amount);
    }

    function getRefundableBounty(address who) external view returns (uint256) {
        return ArbiterRegistryStorage.data().refundableBounty[who];
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
            // the same device this file already uses to reset XP on a demotion
            // (_recordArbiterMistake).
            RegistryStorage.AgreementRecord storage rec = RegistryStorage.store().agreements[agreement];
            if (rec.client != address(0)) {
                ReputationStorage.Data storage rep = ReputationStorage.data();
                rep.unresolvedDisputes[rec.client]   += 1;
                rep.unresolvedDisputes[rec.executor] += 1;
            }

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
        require(ok, "ArbiterRegistry: status read failed");
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

    function getChiefArbiter()  external view returns (address) { return ArbiterRegistryStorage.data().chiefArbiter; }
    function isRegisteredArbiter(address addr) external view returns (bool) { return ArbiterRegistryStorage.data().isArbiter[addr]; }
    function getArbiters()      external view returns (address[] memory) { return ArbiterRegistryStorage.data().arbiterList; }
    function getDisputeClaimer(address agreement) external view returns (address) { return ArbiterRegistryStorage.data().disputeClaims[agreement]; }

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

    function getClaimCommitment(bytes32 c) external view returns (uint256) { return ArbiterRegistryStorage.data().claimCommitments[c]; }

    function getPendingVerdict(address agreement) external view returns (ArbiterRegistryStorage.PendingVerdict memory) {
        return ArbiterRegistryStorage.data().pendingVerdicts[agreement];
    }

    function getVaultBalance()  external view returns (uint256) { return ArbiterRegistryStorage.data().vaultBalance; }
    /// @notice The path was retired on 31 July 2026 (see setRewardPerDispute) — the
    /// field this function reads is written by nobody any more, the value is always 0.
    function getRewardPerDispute() external view returns (uint256) { return ArbiterRegistryStorage.data().rewardPerDispute; }
    function getDAOAddress()    external view returns (address) { return ArbiterRegistryStorage.data().daoAddress; }
    /// @notice Who is named as successor and has not taken office. Zero means no proposal.
    /// Without this read the second step would be visible only to someone who
    /// scans raw logs: the named address cannot check that it is the one named,
    /// and the owner cannot check that he did not mistype a letter.
    function getPendingDAOAddress() external view returns (address) { return ArbiterRegistryStorage.data().pendingDaoAddress; }

    /// @notice Public (not external) because quoteDisputeTopUp calls it
    /// directly — the default at zero is substituted in one place, not two.
    function getArbiterFloor() public view returns (uint256) {
        uint256 f = ArbiterRegistryStorage.data().arbiterFloor;
        return f == 0 ? DEFAULT_ARBITER_FLOOR : f;
    }

    /// @notice The discount the vault takes off a top-up, before it is capped
    /// by what the vault actually holds. Public (not external) for the same
    /// reason as the floor above: `_splitTopUp` calls it, so the default at
    /// zero is substituted in one place instead of two.
    function getDisputeDiscount() public view returns (uint256) {
        uint256 v = ArbiterRegistryStorage.data().disputeVaultDiscount;
        return v == 0 ? DEFAULT_DISPUTE_DISCOUNT : v;
    }
    function hasSubmittedVerdict(address agreement) external view returns (bool) {
        return ArbiterRegistryStorage.data().pendingVerdicts[agreement].submittedAt != 0;
    }
    function getAppealVotes(address agreement) external view returns (uint256 uphold, uint256 overturnVotes) {
        ArbiterRegistryStorage.PendingVerdict storage v = ArbiterRegistryStorage.data().pendingVerdicts[agreement];
        return (v.votesUphold, v.votesOverturn);
    }

    function hasVotedOnAppeal(address agreement, address arbiterAddr) external view returns (bool) {
        return ArbiterRegistryStorage.data().hasVotedAppeal[agreement][arbiterAddr];
    }
    /// @notice How much must be topped up for the arbiter to receive the floor in total.
    /// Returns 0 when the pot is already large enough — the top-up button should
    /// then not be shown at all.
    ///
    /// The fee is taken FROM THE DEAL by calling disputeFee(), not recomputed here.
    /// The fee formula (3% with a cap) lives in Agreement, and a second copy in
    /// the facet would drift from it on the very first edit — silently, because
    /// the divergence is visible only to someone who compares the number shown
    /// with the one that arrived in the wallet.
    function quoteDisputeTopUp(address agreement) public view returns (uint256) {
        (uint256 gross, uint256 subsidy) = _splitTopUp(agreement);
        return gross - subsidy;
    }

    /// The whole top-up to the floor, and the vault's share of it — computed in
    /// ONE place, read by `quoteDisputeTopUp`, `quoteDisputeSubsidy` and
    /// `fundDispute`. The screen and the transfer therefore cannot disagree:
    /// they are the same subtraction, not two subtractions that match today.
    ///
    /// `gross` is what the arbiter must additionally receive to reach the
    /// floor; `subsidy` is what the bank puts in; the party pays the rest.
    function _splitTopUp(address agreement) private view returns (uint256 gross, uint256 subsidy) {
        (bool statusOk, bytes memory statusData) = agreement.staticcall(
            abi.encodeWithSignature("status()")
        );
        require(statusOk, "ArbiterRegistry: failed to read status");
        if (abi.decode(statusData, (uint8)) != 4) revert NotDisputed();

        (bool feeOk, bytes memory feeData) = agreement.staticcall(
            abi.encodeWithSignature("disputeFee()")
        );
        require(feeOk, "ArbiterRegistry: failed to read dispute fee");
        uint256 fee = abi.decode(feeData, (uint256));

        uint256 arbiterGets = (fee * ARBITER_SHARE_BPS) / 10_000;
        uint256 floor_ = getArbiterFloor();
        if (arbiterGets >= floor_) return (0, 0);
        gross = floor_ - arbiterGets;

        // An empty bank does not refuse the dispute, it simply gives nothing:
        // the party in a dispute must never hit a revert because of somebody
        // else's treasury. This is also the whole of the "vault is short"
        // handling — there is no other branch anywhere, because the money is
        // taken out of the vault here and now rather than promised for later.
        subsidy = getDisputeDiscount();
        uint256 bank = ArbiterRegistryStorage.data().vaultBalance;
        if (subsidy > bank) subsidy = bank;

        // The discount never swallows the top-up whole, even when it would
        // cover it. Two reasons, and the second one alone would be enough:
        //
        //   * zero from `quoteDisputeTopUp` already MEANS something — "there is
        //     nothing to pay", which `fundDispute` answers with TopUpNotNeeded
        //     and the deal screen answers by hiding the button. A second
        //     meaning for the same zero would hide the button on exactly the
        //     pots where the bank pays for everything, and the dispute would
        //     sit there with no judge and no way to buy one.
        //   * the vault's share is a discount and not cover: an empty dispute that
        //     costs the opener nothing is one that gets opened for nothing.
        //
        // Reachable only above a ~$292 pot, where the levy already leaves the
        // arbiter more than $7 and the whole top-up is under three dollars.
        if (subsidy >= gross) subsidy = gross - 1;
    }

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
    /// not reach the quorum" (16 August 2026). resolveAppeal settles by a simple
    /// majority of the votes cast as soon as APPEAL_MIN_VOTES of them exist:
    /// with three cast, two decide. addArbiter does not let this number grow to
    /// a deciding majority for the chief's own seatings, that is, it holds it
    /// at one.
    ///
    /// ⚠️ What this does NOT give and does not promise: with a large corps the
    /// quorum stays an ABSOLUTE three, and any three who collude decide
    /// everything — the cap counts only the chief's people and does not touch
    /// such a three. Tying the quorum to the corps size is separate work, not done here.
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
