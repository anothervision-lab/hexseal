// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════
// FROZEN SNAPSHOT OF A SHIPPED FACET — THE CODE IS NOT EDITED
// ════════════════════════════════════════════════════════════════════════
//
// WHAT THIS IS. The CODE below is a verbatim copy of
// `src/facets/ArbiterRegistryFacet.sol` as it stood in the source the facet
// deployed to Base Sepolia on 15 August 2026 was built from
// (`0x1CF4c7DaA27f2241eafd8E818329719418403013`, 64 arbiter selectors). Only
// names were changed, so that the copy could live in one project with the
// original:
//   ArbiterRegistryFacet       → LegacyPreSplitArbiterFacet
//   ArbiterRegistryStorage     → LegacyArbiterRegistryStorage
//   IUSDCFull/IAgreementStatus → ILegacyUSDCFull/ILegacyAgreementStatus
//   import "../RegistryFacet.sol" → "../../src/RegistryFacet.sol" (the file moved
//     two levels down, the path was recomputed)
// Not one line of LOGIC was touched. That was proved once, by hand, by a diff
// against the shipped source with those four renames undone.
//
// ⚠️ THE COMMENTS ARE NOT VERBATIM. They were translated from Russian into
// English on 30 August 2026, for the same reason the rest of the repository was:
// it is read by people who do not read Russian. So the claim this file makes about
// itself is narrower than it used to be, and this is its honest form:
//   - the CODE is identical to the pre-split facet, character for character once
//     comments are set aside;
//   - the COMMENT TEXT is a translation, and is NOT what the shipped source said.
// The lock in `test/PresentationRecordUpgrade.t.sol` was rebuilt to guard exactly
// that and nothing more: it hashes this file WITH COMMENTS STRIPPED AND WHITESPACE
// COLLAPSED, so an edit to the code turns it red while an edit to a comment does
// not. Before the translation the lock hashed the file's whole text, comments
// included — which after the translation would have been a lock on a claim that
// is no longer true.
//
// WHY IT EXISTS. The benches of the executed cuts (`test/ArbiterChatKeyUpgrade.t.sol`,
// `test/PresentationRecordUpgrade.t.sol`) must reproduce the layout of the chain AS
// IT WAS THEN: every arbiter selector on ONE address, and that address must REALLY
// answer them — the pre-flight of those scripts genuinely calls
// getArbiters()/getVaultBalance()/getArbiterFloor()/getOpenClaimCount, and
// `checkReplaceGroup` demands a single address for the whole group.
//
// WHY A SNAPSHOT AND NOT AN HEIR. This double used to be declared as
// `contract LegacyPreSplitArbiterFacet is ArbiterRegistryFacet` and appended the
// fourteen readers that later moved into the accountability facet. That is, it
// INHERITED today's code and followed its every edit — while being declared as the
// layout of the CHAIN. Two troubles at once:
//   - it grew along with the production facet and on 16 August crossed EIP-170
//     (24 646 → 24 722 against a limit of 24 576): `forge build --sizes` answered
//     with exit code 1. A layout that CANNOT be deployed does not describe the
//     chain by definition;
//   - it showed the benches today's behaviour under the guise of yesterday's —
//     silently, and more so the further it went.
// The snapshot removes both by construction: 21 227 bytes (3 349 to spare), and
// edits in `src/` do not move it at all.
//
// ⚠️ THE CODE OF THIS FILE IS NOT EDITED. It describes THE PAST. If a snapshot of
// the next shipped state is needed, a SECOND file is started beside it, with its own
// origin in its own header, and this one stays as it is. The duplication of the
// storage library here is not carelessness but the condition of the freeze: pulling
// the library from `src/` would mean following today's edits again — the signature
// of `recordAutomaticRemoval` has changed since, and against a live library this
// copy would no longer compile.
//
// ⚠️ It is not in `src/` and must not be: it exists so that the past can be
// reproduced, not so that the readers get two homes.
//
// ════════════════════════════════════════════════════════════════════════
// Below is the file's own header at the moment of the snapshot, translated.
// ════════════════════════════════════════════════════════════════════════

// ============================================================
// HEXSEAL — ArbiterRegistryFacet.sol
//
// Arbiter registry + DAO mode + Diamond-as-arbiter + rewards
//
// Architecture:
//   1. An arbiter claims a dispute through commit-reveal → the Diamond becomes the arbiter in Agreement
//   2. The arbiter calls submitVerdict(agreement, clientWins) → the verdict is queued
//   3. Anyone calls finalizeVerdict(agreement) → the Diamond executes resolveDispute
//   4. Owner/DAO may overturnVerdict before finalization → the arbiter's XP is slashed, no payout is made
//
// FeeVault: topped up by hand (fundVault) and holds a buffer against the future needs
//   of the arbiter bank (Treasury.distribute()), but no longer pays for a particular
//   dispute — the flat rewardPerDispute payout was rejected by the design of 28 July
//   and taken out on 31 July (setRewardPerDispute now reverts RewardPathRetired, the
//   rewardPerDispute field is dead). Payment for a verdict today comes from two
//   sources: creditDisputeFee (80% of the 3% fee on the disputed amount — the
//   internal design of arbitration economics, not published) and
//   disputeBounty — a top-up by a party to the dispute up to arbiterFloor on a small
//   pot (fundDispute), which goes to the arbiter on finalization in finalizeVerdict.
//   The arbiter collects what has accumulated through withdrawArbiterReward().
//
// DAO mode: when uniqueActiveUsers >= 100,000 OR owner.activateDAO() —
//   users with XP >= 3000 may join by themselves through applyAsArbiter().
// ============================================================

import "../../src/FactoryFacet.sol";         // FactoryStorage (trustedForwarder, usdc)
import "../../src/DiamondProxy.sol";          // OwnershipLib
import "../../src/facets/ReputationFacet.sol"; // ReputationStorage (XP + cleanStreak + uniqueActiveUsers)
import "../../src/RegistryFacet.sol";                // RegistryStorage — verifying notifyArbiterTimeout's caller

// ---------- INTERFACES ----------

interface ILegacyAgreementStatus {
    function status()    external view returns (uint8);
    function setArbiter(address newArbiter) external;
    function client()    external view returns (address);
    function executor()  external view returns (address);
    function amount()    external view returns (uint256);
    function disputedAt() external view returns (uint256);
}

interface ILegacyUSDCFull {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ---------- STORAGE ----------

library LegacyArbiterRegistryStorage {
    /// @custom:storage-location erc7201:hexseal.arbiterregistry.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.arbiterregistry.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant POSITION = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    struct PendingVerdict {
        address arbiter;        // who submitted the verdict
        bool    clientWins;     // the outcome
        uint256 submittedAt;    // timestamp of submission
        bool    frozen;         // frozen by owner/DAO (cannot be finalized)
        bool    finalized;      // executed on Agreement
        bool    overturned;     // overturned by owner/DAO (no payout, XP slashed)
        bool    executing;      // finalizeVerdict is running — do not delete through clearDisputeClaim
        // ── User-initiated appeal (pre-finalization only) ──
        bool    appealed;        // appeal filed
        bool    appealResolved;  // appeal voting finished
        address appellant;       // who filed the appeal — for the refund/forfeit of the deposit
        uint256 appealDeadline;  // deadline of the voting window
        uint256 votesUphold;     // votes to "leave as is"
        uint256 votesOverturn;   // votes to "overturn"
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
        uint256                            rewardPerDispute; // DEAD. The flat payout from the bank was rejected
                                                              // by the design of 28.07 and taken out on 31.07; the field is kept
                                                              // because the layout is append-only. Do not read and do not write.
        uint256                            vaultBalance;     // USDC held by Diamond for rewards
        address                            daoAddress;       // future DAO governance contract
        // ── Provisional status ──
        mapping(address => uint256)        arbiterMistakeStreak; // arbiter → judicial mistakes in a row
        // ── Sybil-resistance: forfeitable bond ──
        mapping(address => uint256)        arbiterBond;           // arbiter → locked USDC bond
        mapping(address => uint256)        openClaimCount;        // arbiter → how many disputes are claimed right now and not closed
        // ── Appeal voting ──
        mapping(address => mapping(address => bool)) hasVotedAppeal; // agreement → arbiter → has already voted
        // ── Dispute settlement fee (3% of the disputed amount, computed by Agreement) ──
        // The treasury's share of disputes (20% of the fee). Credited rather than transferred at
        // settlement time: a blocked feeRecipient would otherwise bring down every dispute.
        uint256                            treasurySlice;
        // ── Paid call for an arbiter ──
        // A top-up to a workable threshold: on a small pot 80% of the 3% fee does not
        // pay for even fifteen minutes of reading, and nobody takes the dispute.
        // The party that needs a judge pays, so a subsidy out of the common
        // bank — and the farming that comes with it — is not required.
        mapping(address => uint256)        disputeBounty;      // agreement → top-up paid in
        mapping(address => address)        disputeBountyPayer; // agreement → who paid it in
        uint256                            arbiterFloor;       // how much the arbiter must receive in total
        // Soft refund of the top-up: clearDisputeClaim pushes transfer() and, if
        // it was not delivered (the payer is on the USDC blacklist), does not revert —
        // Agreement calls this function inside an empty try/catch
        // (Agreement._clearDisputeClaim), and a hard revert here would drag down the release
        // of the claim and the decrement of openClaimCount in silence. What was not delivered
        // piles up here and is pulled out through withdrawDisputeBounty().
        mapping(address => uint256)        refundableBounty;   // payer → undelivered refund, collected by the payer themselves
        // ── Arbiter chat keys (9 August 2026) ──
        // The public halves of the chat keys: encryption (X25519) and signing (Ed25519).
        // They live HERE and not in the relayer's directory, at the owner's demand:
        // arbiters must be regulated by the diamond, not by the owner. The directory lived
        // on the project's server, and whoever reached that server would slip in a
        // key of their own in place of the arbiter's and read ALL presentations across all
        // disputes without giving themselves away. Here the arbiter writes the key with their
        // own transaction — the server stopped being a point of substitution, and that is the
        // whole gain of this work.
        //
        // The diamond's owner remained a point of substitution: the right to upgrade allows
        // deploying a small facet with a function that writes into the arbiterBoxKey of an
        // arbitrary address, mounting it through diamondCut, rewriting the
        // key, reading the parties' presentations and taking the facet off again. ArbiterChatKeySet
        // does NOT fly while that happens — the parties' apps will not see the change. The same class
        // and the same order of price as the already-measured bypass of the treasury reserve gate
        // (~31 700 gas, invisible to the loupe).
        //
        // The private halves NEVER reach the chain: they are derived from
        // the arbiter's signature and stay on their device. The public half being public
        // is not a leak but a condition of the work: a party takes it in order to
        // seal a presentation so that only the holder of the private half can
        // open it.
        mapping(address => bytes32)        arbiterBoxKey;   // arbiter → public encryption key
        mapping(address => bytes32)        arbiterSignKey;  // arbiter → public signing key
        // ── The moment a dispute was claimed (14 August 2026) ──
        // Needed for the floor on the silence record: the chain does not accept "no answer"
        // earlier than NO_RESPONSE_FLOOR from the claim. The count runs from here and not
        // from the request: the request goes off-chain and the arbiter could forge its time,
        // while "claimed the dispute at block N" is a ready fact. It is also the moment from
        // which a party can physically present: before it the arbiter's key is unknown.
        //
        // The key is a PAIR (agreement, arbiter). Not "agreement → time": otherwise a new
        // arbiter would inherit the old one's time, the floor would turn out to be already
        // passed, and the silence record would go through the same second they claimed the
        // dispute. Keying by a pair removes this structurally and at the same time removes the
        // need to zero it on release of the claim — there are two places of release and a
        // candidate for a third (an abandonClaim that clears the counter), and the cleanup would
        // have to be remembered there too. What is handed outwards is the anchor of the CURRENT
        // claimer, see getDisputeClaimedAt.
        //
        // ⚠️ Written on EVERY claim by this arbiter, not only on the first.
        // The owner's decision of 14.08.2026, overriding an earlier "once and
        // for all". The floor must measure the time during which the party had
        // SOMEONE to present to — that is, while the dispute stood with this arbiter. With
        // an anchor of "the first claim, forever" a bribed arbiter claimed the dispute,
        // released it a minute later and came back a day later: the floor is passed, the silence
        // record goes through immediately, while the dispute stood ownerless almost all that
        // time and there was nobody to present to.
        //
        // The other side — that re-claiming moves the anchor forward — is not a weapon:
        // moving forward only POSTPONES the record, that is, it harms the arbiter
        // themselves. The order of events is visible not from here but from the
        // DisputeClaimed / DisputeNoResponseRecorded events: storage holds
        // the last claim, the feed holds every one.
        mapping(address => mapping(address => uint256)) disputeClaimedAtBy;
        // The record "asked for the correspondence, no answer" — the block second. 0 — no record.
        // The key is the same, the pair (agreement, arbiter), but the writing rule is DIFFERENT:
        // it is written ONCE and never erased. An erasable or rewritable
        // record would mean the arbiter is free to move its time — released
        // the dispute, claimed it again, recorded again — and "when exactly they asserted this"
        // becomes their choice rather than a fact. The anchor has no such freedom: it
        // can be moved forward only, and only to its owner's harm.
        mapping(address => mapping(address => uint256)) disputeNoResponseAtBy;
        // ── Presentation digests (14 August 2026) ──
        // Agreement → a list of 32-byte hashes of the canonical form a party
        // SIGNS a presentation with (canonicalPresentationBytes in the client's
        // presentation module).
        //
        // A list rather than a single value: the correspondence does not fit into one bag, and
        // there can be as many presentations per dispute as needed. The key is
        // the agreement, not the pair (agreement, party): what is proved is the ORDER, and the
        // order is common to the dispute, so the feed must be read in one request. Who exactly
        // put it there is visible from the event — in storage nobody needs it.
        //
        // What is immortal is the digest, not the correspondence: the store is cleaned,
        // the 32 bytes remain. From the same reasoning comes what is NOT here and must not be —
        // neither deletion nor rewriting: a record that can be taken back
        // proves exactly nothing.
        mapping(address => bytes32[]) presentationDigests;
    }

    function data() internal pure returns (Data storage d) {
        bytes32 pos = POSITION;
        assembly { d.slot := pos }
    }
}

// ---------- FACET ----------

contract LegacyPreSplitArbiterFacet {

    // -------- CONSTANTS --------

    uint256 private constant COMMIT_MAX_BLOCKS  = 50;         // ~100s on Base
    uint256 private constant DAO_THRESHOLD      = 100_000;   // uniqueActiveUsers for the automatic DAO
    uint256 private constant MIN_XP_TO_REGISTER = 3_000;     // ~30 deals with different people
    uint256 private constant OVERTURN_XP_SLASH  = 200;       // XP penalty on an overturn
    // DEFAULT_REWARD (5 USDC) was deleted on 31 July: not a single call read it, while
    // the comment above it called it "the floor of the formula" — when the real
    // floor of the arbiter's payout is DEFAULT_ARBITER_FLOOR below. Two constants with
    // one word in their description and one of them dead is a false trail, not
    // documentation.
    uint256 private constant FINALIZE_DELAY      = 24 hours;  // window for owner/DAO/appeal before finalization (was 1 hour — not enough for an ordinary user)

    // The floor on the silence record: this much must pass from the CLAIM of the dispute
    // before an arbiter may record "asked, no answer". The owner's decision of 14.08.2026.
    // Deliberately the same as FINALIZE_DELAY: one familiar number instead of two similar ones.
    //
    // ⚠️ This is the ONLY place the number is declared. The client must read it
    // through getNoResponseFloor() rather than keep a copy.
    uint256 private constant NO_RESPONSE_FLOOR = 24 hours;

    uint256 private constant MIN_CLEAN_STREAK_TO_REGISTER = 10;   // the same streak that keeps an executor's XP above 1000
    uint256 private constant MAX_ARBITER_MISTAKES         = 3;    // mistakes in a row before the status is taken away
    uint256 private constant DEMOTION_XP_RESET            = 2500; // a fixed reset on demotion — not a subtraction
    uint256 private constant ARBITER_BOND                 = 50_000_000; // 50 USDC (6 decimals) — forfeited on demotion, returned on resignAsArbiter()

    uint256 private constant APPEAL_REVIEW_WINDOW = 4 days;     // as much as DISPUTE_WINDOW gives the arbiter
    uint256 private constant APPEAL_MIN_VOTES     = 3;          // quorum of other arbiters
    uint256 private constant APPEAL_DEPOSIT       = 20_000_000; // 20 USDC (6 decimals) — flat, NOT a % of the deal amount

    uint256 private constant ARBITER_SHARE_BPS = 8_000; // 80% of the fee to the arbiter, the remainder to the treasury

    uint256 private constant DEFAULT_ARBITER_FLOOR = 10_000_000; // 10 USDC (6 decimals)

    // -------- EVENTS --------

    event ArbiterAdded(address indexed arbiter);
    event ArbiterRemoved(address indexed arbiter);
    event ChiefArbiterSet(address indexed prev, address indexed next);
    event DisputeClaimCommitted(address indexed arbiter, bytes32 indexed commitment);
    event DisputeClaimed(address indexed agreement, address indexed arbiter);
    event DisputeReleased(address indexed agreement, address indexed prevArbiter);
    /// An arbiter recorded on chain: asked a party for the correspondence — there was no answer.
    /// The event carries the same as storage and exists for the appeal feed:
    /// storage shows only the record of the CURRENT claimer, while an appeal
    /// looks at the whole course of the dispute, including arbiters who have released it.
    event DisputeNoResponseRecorded(address indexed agreement, address indexed arbiter, uint256 at);
    /// A party to the dispute put a presentation digest on chain.
    ///
    /// ⚠️ THE EVENT IS MANDATORY, and not as a duplicate of storage: storage answers
    /// "how many and which", while a dispute is decided by the question "what came first".
    /// The block number and the order relative to DisputeNoResponseRecorded exist only in
    /// the feed. `index` duplicates the place in the list on purpose — whoever reads the
    /// feed is not obliged to go to storage to understand whether this is the first
    /// presentation or the tenth.
    event PresentationDigestRecorded(
        address indexed agreement, address indexed submitter, bytes32 digest, uint256 index
    );
    event DAOActivated(address indexed by);
    event ArbiterApplied(address indexed arbiter);
    /// The arbiter's chat keys have been published or replaced.
    ///
    /// ⚠️ THE EVENT IS MANDATORY, and here is why: the client watches for a key change in
    /// order to present again automatically if the arbiter changed device. Without
    /// the event it would have to POLL the chain — and on 9 August 8 100 chain
    /// requests an hour from a single tab were taken out, and a new poll would bring the
    /// same trouble back under another name. Do not delete and do not make it non-indexable.
    event ArbiterChatKeySet(address indexed arbiter, bytes32 boxKey, bytes32 signKey);
    event VerdictSubmitted(address indexed agreement, address indexed arbiter, bool clientWins);
    event VerdictFinalized(address indexed agreement, address indexed arbiter, bool clientWins);
    event VerdictFrozen(address indexed agreement);
    event VerdictUnfrozen(address indexed agreement);
    event VerdictOverturned(address indexed agreement, address indexed arbiter, bool newClientWins);
    event ArbiterRewarded(address indexed arbiter, uint256 amount);
    event ArbiterRewardWithdrawn(address indexed arbiter, uint256 amount);
    event VaultFunded(address indexed by, uint256 amount);
    // RewardPerDisputeUpdated was deleted on 31 July together with the last thing that
    // sent it: setRewardPerDispute became a `pure revert`, there is nobody left to write
    // the value. A declaration without a single emit is the promise of an event that will
    // not happen, to everyone who reads the ABI.
    event DAOAddressSet(address indexed daoAddress);
    event StuckVerdictAutoCleared(address indexed agreement);
    event AppealRaised(address indexed agreement, address indexed appellant);
    event AppealVoteCast(address indexed agreement, address indexed arbiter, bool overturn);
    event AppealResolved(address indexed agreement, address indexed appellant, bool overturned);
    event ArbiterDemoted(address indexed arbiter);
    event ArbiterResigned(address indexed arbiter, uint256 bondRefunded);
    event DisputeFeeCredited(address indexed arbiter, uint256 toArbiter, uint256 toTreasury);
    event TreasurySlicePushed(address indexed to, uint256 amount);
    event ArbiterFloorUpdated(uint256 amount);
    event DisputeBountyFunded(address indexed agreement, address indexed payer, uint256 amount);
    event DisputeBountyRefunded(address indexed agreement, address indexed payer, uint256 amount);
    event DisputeBountyRefundable(address indexed agreement, address indexed payer, uint256 amount);
    event DisputeBountyWithdrawn(address indexed payer, uint256 amount);

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
    // An error of its own rather than NothingToPush: that one lives in withdrawTreasurySlice.
    // Both are taken apart by the relayer's decoder (its list of custom forwarder
    // errors, selectors 0x2d4e8c7b and 0x68d369c9), that is, the name
    // reaches the human verbatim — and a human collecting their own top-up
    // would see a message about a push they never made. The separation works
    // exactly insofar as both errors are in the decoder: miss one, and
    // what reaches the human is raw hex, in which there is nothing to tell apart.
    error NoRefundableBounty();
    error ZeroAmount();
    // The name reflects the check actually guarded: the source of the arbiter is
    // pendingVerdicts, so the gate hits the absence of a verdict, not of a claimer
    // (claim and verdict diverged after the arbiter argument was taken out
    // of creditDisputeFee — see the comment above the function).
    error NoVerdictSubmitted();
    error TopUpNotNeeded();
    error BountyAlreadyFunded();
    error DisputeAlreadyClaimed();
    error NotParty();
    error RewardPathRetired();

    // ── The record "asked, no answer" ──
    error NoResponseTooEarly();
    error NoResponseAlreadyRecorded();
    /// Deliberately separate from NotTheClaimer: that one answers on the verdict path, and
    /// a party who saw it in response to the "there was no answer" button would decide
    /// the problem was in the verdict. The same meaning, different screens.
    error NotClaimingArbiter();
    error ClaimTimeUnknown();

    // ── Presentation digest ──
    /// Deliberately separate from NotParty, for the same reason NotClaimingArbiter is
    /// separate from NotTheClaimer: NotParty lives on the arbiter PAYMENT path
    /// (fundDispute), and a person who got it in response to "present the
    /// correspondence" would go looking for a problem in the money. One meaning, different screens.
    error NotDisputeParty();
    /// A zero digest is not a presentation but an empty entry in the feed: zero has no
    /// preimage that can be shown.
    error ZeroDigest();

    // -------- MODIFIERS --------

    modifier onlyOwner() {
        if (OwnershipLib.contractOwner() != msg.sender) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrChief() {
        address chief = LegacyArbiterRegistryStorage.data().chiefArbiter;
        if (msg.sender != OwnershipLib.contractOwner() && msg.sender != chief)
            revert NotOwnerOrChief();
        _;
    }

    modifier onlyOwnerOrDAO() {
        address dao = LegacyArbiterRegistryStorage.data().daoAddress;
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

    function activateDAO() external onlyOwner {
        LegacyArbiterRegistryStorage.data().daoActiveManual = true;
        emit DAOActivated(msg.sender);
    }

    function applyAsArbiter() external {
        if (!isDaoActive()) revert DAONotActive();

        address caller = _msgSender();
        ReputationStorage.Data storage rep = ReputationStorage.data();
        uint256 xp = rep.xp[caller];
        if (xp < MIN_XP_TO_REGISTER) revert InsufficientXP(xp, MIN_XP_TO_REGISTER);
        uint256 streak = rep.cleanStreak[caller];
        if (streak < MIN_CLEAN_STREAK_TO_REGISTER) revert InsufficientCleanStreak(streak, MIN_CLEAN_STREAK_TO_REGISTER);

        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        if (d.isArbiter[caller]) revert AlreadyArbiter();

        address usdc = FactoryStorage.store().usdc;
        bool bondOk = ILegacyUSDCFull(usdc).transferFrom(caller, address(this), ARBITER_BOND);
        require(bondOk, "ArbiterRegistry: bond transfer failed");
        d.arbiterBond[caller] = ARBITER_BOND;

        d.isArbiter[caller] = true;
        d.arbiterList.push(caller);

        emit ArbiterAdded(caller);
        emit ArbiterApplied(caller);
    }

    /// @notice Stepping down from arbiter status voluntarily, without penalty. Returns the bond
    /// in full. Without this, arbiter status would be a one-way road for those who were
    /// never demoted — the bond would be locked forever at the moment a person simply
    /// wants to stop.
    function resignAsArbiter() external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
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
            bool ok = ILegacyUSDCFull(usdc).transfer(caller, bond);
            require(ok, "ArbiterRegistry: bond refund failed");
        }

        emit ArbiterResigned(caller, bond);
    }

    // -------- ADMIN: MANAGE ARBITERS --------

    function setChiefArbiter(address arbiter) external onlyOwner {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        emit ChiefArbiterSet(d.chiefArbiter, arbiter);
        d.chiefArbiter = arbiter;
    }

    function addArbiter(address arbiter) external onlyOwnerOrChief {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        if (d.isArbiter[arbiter]) revert AlreadyArbiter();
        d.isArbiter[arbiter] = true;
        d.arbiterList.push(arbiter);
        emit ArbiterAdded(arbiter);
    }

    function removeArbiter(address arbiter) external onlyOwnerOrChief {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        if (!d.isArbiter[arbiter]) revert NotAnArbiter();
        d.isArbiter[arbiter] = false;
        uint256 len = d.arbiterList.length;
        for (uint256 i = 0; i < len; i++) {
            if (d.arbiterList[i] == arbiter) {
                d.arbiterList[i] = d.arbiterList[len - 1];
                d.arbiterList.pop();
                break;
            }
        }

        uint256 bond = d.arbiterBond[arbiter];
        if (bond > 0) {
            d.arbiterBond[arbiter] = 0;
            address usdc = FactoryStorage.store().usdc;
            bool ok = ILegacyUSDCFull(usdc).transfer(arbiter, bond);
            require(ok, "ArbiterRegistry: bond refund failed");
        }

        emit ArbiterRemoved(arbiter);
    }

    // -------- ARBITER: CLAIM DISPUTE --------

    function commitDisputeClaim(bytes32 commitment) external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        if (!d.isArbiter[caller]) revert NotArbiter();
        d.claimCommitments[commitment] = block.number;
        emit DisputeClaimCommitted(caller, commitment);
    }

    /// Publish or replace the public halves of one's own chat keys.
    ///
    /// Needed separately from the dispute claim for one case: an arbiter who lost the
    /// key AFTER claiming gets stuck — the address on chain is the same, but there is
    /// nothing to read the presented material with, and presenting again to the same key
    /// will not help. With this function the loop closes by itself: published a new one →
    /// the parties' apps noticed by the event → presented again → readable.
    ///
    /// The address is taken from the sender, there is NO "to whom" argument at all: someone
    /// else's key cannot be written not because it is checked, but because there is nowhere
    /// to write it.
    ///
    /// ⚠️ The exception where the loop does NOT close by itself: the gate here is `isArbiter`,
    /// and it is removed (removeArbiter/resignAsArbiter/demotion on 3 mistakes
    /// in a row) without clearing the key already written. An arbiter who lost their status
    /// with an open dispute in hand can no longer rotate the key (this
    /// function reverts `NotArbiter`), while `getArbiterChatKeys` still returns
    /// the old one for them — alive to the eye, but there is nobody to replace it.
    /// `submitVerdict` does not cover this case: it checks only
    /// `disputeClaims`, never `isArbiter`. The real cure (allowing
    /// rotation while `openClaimCount` is not empty) changes rights and is deliberately
    /// not implemented here.
    function setArbiterChatKey(bytes32 boxKey, bytes32 signKey) external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        if (!d.isArbiter[caller]) revert NotArbiter();
        if (boxKey == bytes32(0) || signKey == bytes32(0)) revert ZeroChatKey();

        // The event fires only if at least one half really changed.
        // The write is always done (it is idempotent and cheaper than branching) — the condition
        // is only around the emit. The reason lies in the client, not here: it presents again
        // BY THE EVENT, and an identical rewrite — an ordinary no-op from the client
        // (a repeated call, a race between tabs) — would otherwise force it to
        // re-encrypt and re-upload the correspondence for every open
        // dispute of the arbiter, even though the key did not change at all.
        bool changed = d.arbiterBoxKey[caller] != boxKey || d.arbiterSignKey[caller] != signKey;
        d.arbiterBoxKey[caller]  = boxKey;
        d.arbiterSignKey[caller] = signKey;
        if (changed) emit ArbiterChatKeySet(caller, boxKey, signKey);
    }

    /// @notice Claiming a dispute. The Diamond is set as the arbiter in Agreement (not the arbiter themselves).
    /// This lets the Diamond control the execution of the verdict (delay, overturn).
    ///
    /// The chat keys are MANDATORY arguments, held by the form of the argument rather than by a
    /// check: the contract cannot tell a real key from two garbage
    /// bytes32 — the form only makes it impossible to claim a dispute while sending
    /// nothing at all. This closes the case WITHOUT ill intent (forgot, did not set up
    /// the device). An arbiter who deliberately brings garbage instead of a key
    /// is not stopped by the form: they get the same outcome, and the parties will
    /// pointlessly re-encrypt the correspondence to a key nobody owns. A deliberate
    /// refusal to read is closed by detection, not by the form of an argument — that is
    /// the work of later parts, not of this one.
    ///
    /// Every claim REWRITES the keys. ⚠️ It used to say here that this
    /// "cures a change of device by itself" — that is wrong, and was corrected
    /// on 9 August after a review of the client's code. For an ORDINARY wallet the chat key
    /// is deterministic: it is derived from the signature of fixed typed
    /// data (all 65 bytes of the signature go into the seed), and ordinary wallets sign
    /// deterministically (RFC 6979). So the same wallet on a new device
    /// gives THE SAME key, and the key published on chain stays alive — there is nothing
    /// to cure.
    ///
    /// Rewriting is needed where the key really dies, and there are two such cases:
    ///  1. a contract wallet — the key there is random rather than derived, and without a
    ///     recovery code (12 words) a new device gives a different one;
    ///  2. a Safe with threshold 1 — it returns exactly 65 bytes signed by the owner,
    ///     so it is detected as an ordinary wallet, while the key is in fact derived
    ///     from the OWNER's signature. The owner changed — the key changed, and a recovery
    ///     code is not issued to that kind.
    /// Plus the general case: the key is simply lost. For these cases there is also
    /// setArbiterChatKey — there is no need to wait for a claim.
    ///
    /// ⚠️ The selector of this function changed on 9 August. The old
    /// `claimDispute(address,bytes32)` was taken out of the mounting by the same diamondCut —
    /// leaving it would mean keeping a second road on which a dispute is claimed
    /// WITHOUT a key, that is, exactly the hole this change closes.
    function claimDispute(
        address agreement,
        bytes32 salt,
        bytes32 boxKey,
        bytes32 signKey
    ) external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();

        if (!d.isArbiter[caller]) revert NotArbiter();
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

        // Claiming after the verdict window is not allowed. submitVerdict would refuse anyway
        // (DisputeWindowPassed), so a late claim cannot lead to a
        // verdict — but it does set arbiter in Agreement and thereby
        // cancels the splitting of the pot in half on timeout. Without this check a party
        // with a friendly arbiter would take the whole pot having proved nothing.
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

        // The Diamond becomes the arbiter in Agreement — this allows controlling the verdict
        (bool setOk,) = agreement.call(
            abi.encodeWithSignature("setArbiter(address)", address(this))
        );
        require(setOk, "ArbiterRegistry: setArbiter failed");

        d.disputeClaims[agreement] = caller;
        // The floor's anchor — on EVERY claim, without the condition "only if zero".
        // The condition stood here and was taken out by the owner's decision of 14.08.2026: it
        // protected against self-harm (re-claiming postpones the record for the arbiter
        // themselves), and in exchange opened a real hole — claim a dispute, release it a minute
        // later, come back a day later and record silence immediately, though the dispute stood
        // ownerless almost all that time and there was nobody to present to. The details are at
        // the field in LegacyArbiterRegistryStorage.
        d.disputeClaimedAtBy[agreement][caller] = block.timestamp;
        d.arbiterDeals[caller].push(agreement);
        d.openClaimCount[caller]++;

        // The keys are written HERE and not by a separate call: one transaction instead of
        // two, and an arbiter cannot end up registered without a key even for a
        // moment.
        //
        // The event fires only on a real change (see setArbiterChatKey above,
        // the same device and the same reason): without the condition an arbiter with N open
        // disputes, claiming dispute N+1 with their usual key, sends N free
        // repeat presentations to the store — a claim almost always brings THE SAME
        // key that is already written.
        bool keysChanged = d.arbiterBoxKey[caller] != boxKey || d.arbiterSignKey[caller] != signKey;
        d.arbiterBoxKey[caller]  = boxKey;
        d.arbiterSignKey[caller] = signKey;
        if (keysChanged) emit ArbiterChatKeySet(caller, boxKey, signKey);

        emit DisputeClaimed(agreement, caller);
    }

    function releaseDisputeClaim(address agreement) external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();

        address current = d.disputeClaims[agreement];
        if (current == address(0)) revert NotClaimed();
        if (caller != current && caller != OwnershipLib.contractOwner()) revert NotAuthorized();

        // A claim cannot be released once the verdict has been submitted (it awaits finalization)
        require(d.pendingVerdicts[agreement].submittedAt == 0, "ArbiterRegistry: verdict pending");

        // Releasing a dispute after the window closes is not allowed, for the same reason
        // it cannot be claimed after the window: a verdict is already impossible there
        // (submitVerdict will refuse), and the dispute cannot be re-claimed either — so a late
        // release does not return the dispute into circulation.
        //
        // It does harm twice. It leads away from punishment: notifyArbiterTimeout reads
        // disputeClaims and exits silently on an empty key, so an arbiter who never showed up
        // walked away without a judicial mistake. And it switches the timeout branch —
        // setArbiter(0) below turns a full refund to the client into a split
        // in half, which an arbiter friendly to the executor could use for free.
        //
        // Its third effect is useful, and it is lost here: releasing decremented
        // openClaimCount, that is, it freed the arbiter themselves. Until a party
        // pulls triggerArbiterTimeout, the counter of the no-show stays occupied, and
        // with it the exit from the status is locked together with the bond. A deliberate trade:
        // the price is 50 USDC from someone who has already broken the rules, and the owner
        // unlocks it through removeArbiter; the hole would cost half of any disputed pot.
        // The candidate for an honest cure is an abandonClaim that clears the
        // counter, records a mistake and does NOT touch Agreement.arbiter. It is
        // not written.
        //
        // The diamond's owner (the second allowed caller above) falls under the gate
        // the same way. There is a reason for them to unjam someone else's counter,
        // but an exception would bring back exactly this hole, so they unjam
        // through removeArbiter rather than around the gate.
        (bool dOk, bytes memory dData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        require(dOk, "ArbiterRegistry: disputedAt read failed");
        (bool wOk, bytes memory wData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        require(wOk, "ArbiterRegistry: DISPUTE_WINDOW read failed");
        if (block.timestamp > abi.decode(dData, (uint256)) + abi.decode(wData, (uint256))) {
            revert DisputeWindowPassed();
        }

        // The claim anchor and the silence record are NOT touched here: they are keyed
        // by the pair (agreement, arbiter), so "a new arbiter inherits someone else's time"
        // is impossible even without cleanup, and the silence record must not be erased — that
        // would hand the arbiter the right to move its time. Outwards both getters
        // go through disputeClaims, so right after this line they honestly
        // return zero.
        delete d.disputeClaims[agreement];
        if (d.openClaimCount[current] > 0) d.openClaimCount[current]--;

        (bool ok,) = agreement.call(
            abi.encodeWithSignature("setArbiter(address)", address(0))
        );
        require(ok, "ArbiterRegistry: reset arbiter failed");

        emit DisputeReleased(agreement, current);
    }

    /// @notice An arbiter records the fact on chain: asked for the correspondence — there was no answer.
    /// @dev Fired only by the arbiter's word, nothing flies off on a timer.
    /// There are no consequences: no XP, no reputation, no shift of the verdict — the chain does not
    /// see the message box and can believe nothing but the arbiter's word, and hanging automation
    /// on an unverifiable word means handing a bribed arbiter a real weapon.
    /// A presentation digest does NOT stand in the way of the record: a hard ban would give
    /// a party a shield — send the digest of a dummy and become invulnerable.
    function recordNoResponse(address agreement) external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();

        if (d.disputeClaims[agreement] != caller) revert NotClaimingArbiter();

        uint256 claimedAt = d.disputeClaimedAtBy[agreement][caller];
        // Zero means the dispute was claimed BEFORE this field existed: the chain does not know when
        // that was, and there is nothing to count the floor from. The refusal is closed. There is a
        // way out and it is cheap: releaseDisputeClaim and claim the dispute again (owner's decision of 14.08.2026).
        if (claimedAt == 0) revert ClaimTimeUnknown();
        // Uniqueness is checked BEFORE the floor, and the order here is not cosmetic.
        // With an anchor that is moved on every claim, an arbiter who has already
        // made a record and re-claimed the dispute would run into NoResponseTooEarly:
        // an answer that lies — it promises that it will work in a day, while in a
        // day the answer will be NoResponseAlreadyRecorded. "Already recorded" is a state
        // that is final and does not depend on time, which is why it must be
        // answered first.
        if (d.disputeNoResponseAtBy[agreement][caller] != 0) revert NoResponseAlreadyRecorded();
        if (block.timestamp < claimedAt + NO_RESPONSE_FLOOR) revert NoResponseTooEarly();

        d.disputeNoResponseAtBy[agreement][caller] = block.timestamp;
        emit DisputeNoResponseRecorded(agreement, caller, block.timestamp);
    }

    /// @notice A party to the dispute puts a presentation digest on chain — 32 bytes.
    /// @dev This is the `keccak256` of the same canonical form the party
    /// SIGNS the presentation with (`canonicalPresentationBytes` in the client: the
    /// length before every field, no glueing). The hash function is named here verbatim
    /// and not by accident: this is a seam at which the chain sees only 32 bytes and cannot
    /// check the match by anything. Let the client take sha256 — the chain would hold just as
    /// lawful 32 bytes, "it matches" would never match, and the only way that would surface
    /// is through a person with a broken screen. The point is not to prove the content
    /// but to show the ORDER: the digest landed at block N, the arbiter's record "asked,
    /// no answer" at block M. No trust in the project's server is needed for that, and
    /// if the server loses the box, the fact of the presentation remains.
    ///
    /// The digest does NOT stand in the way of the silence record — neither here nor in
    /// recordNoResponse is there a single line tying one to the other.
    /// A hard ban would give a party a shield: the chain does not know what lies under the hash,
    /// so invulnerability would be bought with the digest of an empty file. Who is right
    /// is decided by the arbiter looking at the order, not by the contract.
    function recordPresentationDigest(address agreement, bytes32 digest) external {
        if (digest == bytes32(0)) revert ZeroDigest();

        address caller = _msgSender();

        // The parties are taken from the registry rather than by an external call to the deal.
        // RegistryStorage.AgreementRecord already holds client and executor
        // (src/RegistryFacet.sol), and the other functions of this facet go to the same
        // place (notifyArbiterTimeout, fundDispute). It is cheaper this way, it does not
        // introduce an external call with returndata decoding — and it also answers "is the
        // deal registered at all?": an address that is not in the registry has neither a
        // client nor an executor, so nobody will turn out to be a party to it and
        // nobody will fill the feed of an unregistered deal.
        RegistryStorage.AgreementRecord storage rec =
            RegistryStorage.store().agreements[agreement];
        // ⚠️ The first line CANNOT FIRE today, and this is written here
        // so that the next reader does not take it for a live lock. Entries in the
        // registry are written whole (RegistryFacet.register) and are deleted
        // nowhere, so "there is no entry" means both client == 0 and executor == 0 —
        // and then the second line rejects any non-zero caller by itself.
        // Measured by removal: take the first line out — 0 reds out of 632; take both
        // out — 3 reds. It is kept as a declaration of intent ("the deal must be
        // registered") at the price of one cold SLOAD; if that SLOAD is ever
        // begrudged, it is this line that should go, not the second.
        if (rec.agreement != agreement) revert NotDisputeParty();
        if (caller != rec.client && caller != rec.executor) revert NotDisputeParty();

        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        d.presentationDigests[agreement].push(digest);
        emit PresentationDigestRecorded(
            agreement, caller, digest, d.presentationDigests[agreement].length - 1
        );
    }

    // -------- VERDICT FLOW --------

    /// @notice The arbiter submits a verdict. Not executed yet — it awaits finalizeVerdict.
    function submitVerdict(address agreement, bool clientWins) external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();

        if (d.disputeClaims[agreement] != caller) revert NotTheClaimer();
        if (d.pendingVerdicts[agreement].submittedAt != 0) revert VerdictAlreadySubmitted();

        // Check that the agreement is still in dispute
        (bool ok, bytes memory st) = agreement.staticcall(abi.encodeWithSignature("status()"));
        require(ok, "ArbiterRegistry: status read failed");
        require(abi.decode(st, (uint8)) == 4, "ArbiterRegistry: not disputed");

        // The arbiter must manage to submit the verdict within DISPUTE_WINDOW of disputedAt. This
        // check used to live in Agreement.resolveDispute() and fired at the moment of EXECUTION —
        // because of FINALIZE_DELAY and the appeal, execution legitimately happens much later than
        // submission, so the only place where time must be checked is submission.
        (bool disputedOk, bytes memory disputedData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        require(disputedOk, "ArbiterRegistry: disputedAt read failed");
        uint256 disputedAt = abi.decode(disputedData, (uint256));

        (bool windowOk, bytes memory windowData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        require(windowOk, "ArbiterRegistry: DISPUTE_WINDOW read failed");
        uint256 disputeWindow = abi.decode(windowData, (uint256));

        if (block.timestamp > disputedAt + disputeWindow) revert DisputeWindowPassed();

        d.pendingVerdicts[agreement] = LegacyArbiterRegistryStorage.PendingVerdict({
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
            votesOverturn:  0
        });

        emit VerdictSubmitted(agreement, caller, clientWins);
    }

    /// @notice Execute the verdict. Anyone may call. The Diamond calls resolveDispute on Agreement.
    /// If the verdict is frozen — wait until owner/DAO unfreezes or overturns it.
    function finalizeVerdict(address agreement) external {
        if (agreement == address(0)) revert ArbiterZeroAddress();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        LegacyArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (v.submittedAt == 0) revert NoVerdict();
        if (v.finalized) revert AlreadyFinalized();
        if (v.frozen) revert VerdictFrozenError();
        require(block.timestamp >= v.submittedAt + FINALIZE_DELAY, "ArbiterRegistry: finalize delay not passed");

        // Protection against auto-deletion in clearDisputeClaim during this call
        v.executing = true;

        // The top-up is zeroed HERE, before the external call, whatever the outcome.
        // resolveDispute through the agreement reaches clearDisputeClaim, and if the
        // top-up were still in place, that one would return it to the payer — that is,
        // on an ordinary payout the arbiter and the payer would receive one and the same
        // money. Zeroing before the call makes a double payout impossible by
        // construction rather than by a check.
        uint256 bounty = d.disputeBounty[agreement];
        if (bounty > 0) {
            d.disputeBounty[agreement] = 0;
            address bountyPayer = d.disputeBountyPayer[agreement];
            delete d.disputeBountyPayer[agreement];

            if (v.overturned) {
                // An overturned verdict is not paid for: on an overturn 80% of the fee already
                // goes to the treasury (creditDisputeFee), and the top-up must not be an
                // exception — for one and the same mistake one cannot lose one part
                // of the payment and keep the other. The money goes back to the payer:
                // they bought the resolution of a dispute and did not get it. Through
                // claimable (refundableBounty/withdrawDisputeBounty) rather than
                // a direct transfer — a hard transfer here would bring down the whole
                // finalization if the payer is on the USDC blacklist or otherwise
                // cannot accept a transfer.
                d.refundableBounty[bountyPayer] += bounty;
                emit DisputeBountyRefundable(agreement, bountyPayer, bounty);
            } else {
                d.arbiterRewards[v.arbiter] += bounty;
                emit ArbiterRewarded(v.arbiter, bounty);
            }
        }

        // The Diamond (address(this)) calls resolveDispute — this works because Diamond = arbiter
        (bool ok, bytes memory ret) = agreement.call(
            abi.encodeWithSignature("resolveDispute(bool)", v.clientWins)
        );

        v.executing = false; // always reset, even on a revert

        if (!ok) {
            // bubble up the revert reason from Agreement
            assembly { revert(add(ret, 32), mload(ret)) }
        }

        v.finalized = true;

        // The verdict reached finalization without an overturn — the judicial mistake was not
        // confirmed, and the streak of mistakes is reset.
        if (!v.overturned) {
            d.arbiterMistakeStreak[v.arbiter] = 0;
        }

        emit VerdictFinalized(agreement, v.arbiter, v.clientWins);
    }

    /// @notice Owner or DAO overturn a verdict before finalization.
    /// The arbiter loses XP and the reward. A new verdict is executed instead of the old one.
    function overturnVerdict(address agreement, bool newClientWins) external onlyOwnerOrDAO {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        LegacyArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (v.submittedAt == 0) revert NoVerdict();
        if (v.finalized) revert AlreadyFinalized();
        if (v.appealed && !v.appealResolved) revert AppealInProgress();

        address slashedArbiter = v.arbiter;
        v.clientWins = newClientWins;
        v.overturned = true;
        v.frozen     = false; // unfreeze so that it can be finalized

        // Slash the arbiter's XP
        ReputationStorage.Data storage rep = ReputationStorage.data();
        _slashArbiterXP(rep, slashedArbiter);

        _recordArbiterMistake(d, rep, slashedArbiter);

        emit VerdictOverturned(agreement, slashedArbiter, newClientWins);
    }

    /// @notice Called by Agreement when the arbiter failed to deliver a verdict within DISPUTE_WINDOW
    /// (triggerArbiterTimeout). Counts as a judicial mistake for demotion (unlike
    /// overturnVerdict — XP is not cut here, the verdict was not wrong after all, there simply
    /// was none). The real arbiter is read from disputeClaims and NOT from Agreement.arbiter() —
    /// after claimDispute() that points at the Diamond itself (the Diamond-as-arbiter pattern for
    /// controlling the verdict) rather than at the person who took the dispute. Called BEFORE
    /// _clearDisputeClaim() inside triggerArbiterTimeout, so the record is still in place.
    function notifyArbiterTimeout(address agreement) external {
        if (msg.sender != agreement) revert NotAuthorized();
        if (RegistryStorage.store().agreements[agreement].agreement != agreement) revert NotAuthorized();

        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        address arbiterAddr = d.disputeClaims[agreement];
        if (arbiterAddr == address(0)) return; // nobody claimed the dispute — there is nobody to charge

        ReputationStorage.Data storage rep = ReputationStorage.data();
        _recordArbiterMistake(d, rep, arbiterAddr);
    }

    /// @notice Deducts OVERTURN_XP_SLASH from the arbiter without letting it underflow.
    /// A shared helper for overturnVerdict and resolveAppeal (both cut XP the same way).
    function _slashArbiterXP(ReputationStorage.Data storage rep, address arbiterAddr) private {
        if (rep.xp[arbiterAddr] >= OVERTURN_XP_SLASH) {
            rep.xp[arbiterAddr] -= OVERTURN_XP_SLASH;
        } else {
            rep.xp[arbiterAddr] = 0;
        }
    }

    /// @notice A shared counter of judicial mistakes for overturnVerdict and notifyArbiterTimeout.
    /// On the 3rd mistake in a row: the status is taken away, XP is hard-reset to DEMOTION_XP_RESET
    /// (not a subtraction — one and the same landing point whatever the previous balance),
    /// the mistake counter is zeroed. cleanStreak (the executor streak) is not touched — judging
    /// and carrying out orders are different skills.
    function _recordArbiterMistake(
        LegacyArbiterRegistryStorage.Data storage d,
        ReputationStorage.Data storage rep,
        address arbiterAddr
    ) private {
        uint256 mistakes = d.arbiterMistakeStreak[arbiterAddr] + 1;
        d.arbiterMistakeStreak[arbiterAddr] = mistakes;

        if (mistakes >= MAX_ARBITER_MISTAKES) {
            d.isArbiter[arbiterAddr] = false;
            rep.xp[arbiterAddr] = DEMOTION_XP_RESET;
            d.arbiterMistakeStreak[arbiterAddr] = 0;

            uint256 forfeited = d.arbiterBond[arbiterAddr];
            if (forfeited > 0) {
                d.arbiterBond[arbiterAddr] = 0;
                d.vaultBalance += forfeited;
            }

            uint256 len = d.arbiterList.length;
            for (uint256 i = 0; i < len; i++) {
                if (d.arbiterList[i] == arbiterAddr) {
                    d.arbiterList[i] = d.arbiterList[len - 1];
                    d.arbiterList.pop();
                    break;
                }
            }

            emit ArbiterDemoted(arbiterAddr);
        }
    }

    /// @notice Freeze a verdict (for example while an investigation is under way).
    function freezeVerdict(address agreement) external onlyOwnerOrDAO {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        LegacyArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];
        if (v.submittedAt == 0) revert NoVerdict();
        if (v.finalized) revert AlreadyFinalized();
        v.frozen = true;
        emit VerdictFrozen(agreement);
    }

    /// @notice Unfreeze a verdict.
    function unfreezeVerdict(address agreement) external onlyOwnerOrDAO {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        LegacyArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];
        if (v.appealed && !v.appealResolved) revert AppealInProgress();
        v.frozen = false;
        emit VerdictUnfrozen(agreement);
    }

    // -------- APPEAL FLOW (user-initiated, pre-finalization only) --------

    /// @notice The losing party challenges a verdict before the money has gone to the executor or client.
    /// Requires APPEAL_DEPOSIT — flat, not a % of the deal amount (the amount was chosen by the parties, it cannot
    /// be trusted as the input to anything that can be lost or won).
    function raiseAppeal(address agreement) external {
        if (agreement == address(0)) revert ArbiterZeroAddress();
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        LegacyArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

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
        bool ok = ILegacyUSDCFull(usdc).transferFrom(caller, address(this), APPEAL_DEPOSIT);
        require(ok, "ArbiterRegistry: deposit transfer failed");

        v.appealed       = true;
        v.frozen         = true;
        v.appellant      = caller;
        v.appealDeadline = block.timestamp + APPEAL_REVIEW_WINDOW;

        emit AppealRaised(agreement, caller);
    }

    /// @notice Any registered arbiter except the one who delivered the verdict votes once.
    function voteOnAppeal(address agreement, bool overturn) external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        LegacyArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

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

    /// @notice Sums up the appeal vote. It may be called as soon as the quorum
    /// (APPEAL_MIN_VOTES) is reached — without waiting for the end of the window. If the window closed without
    /// a quorum, the appeal is rejected by default (so it does not hang forever).
    function resolveAppeal(address agreement) external {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        LegacyArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

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
            v.clientWins = !v.clientWins;
            v.overturned = true;

            ReputationStorage.Data storage rep = ReputationStorage.data();
            _slashArbiterXP(rep, slashedArbiter);
            _recordArbiterMistake(d, rep, slashedArbiter);

            bool refundOk = ILegacyUSDCFull(usdc).transfer(v.appellant, APPEAL_DEPOSIT);
            require(refundOk, "ArbiterRegistry: deposit refund failed");
        } else {
            d.vaultBalance += APPEAL_DEPOSIT;
        }

        emit AppealResolved(agreement, v.appellant, overturn);
    }

    // -------- REWARDS --------

    /// @notice The arbiter collects the reward that has accumulated.
    function withdrawArbiterReward() external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();

        uint256 amount = d.arbiterRewards[caller];
        if (amount == 0) revert NoRewardToClaim();

        d.arbiterRewards[caller] = 0;

        address usdc = FactoryStorage.store().usdc;
        bool ok = ILegacyUSDCFull(usdc).transfer(caller, amount);
        require(ok, "ArbiterRegistry: USDC transfer failed");

        emit ArbiterRewardWithdrawn(caller, amount);
    }

    /// @notice Credit the dispute fee. The agreement (Agreement.resolveDispute) calls
    /// this function BEFORE transferring `total` to the diamond, and transfers only if the call
    /// did not revert — so a failed credit does not leave money on the diamond without
    /// a single counter pointing at it (see Agreement.resolveDispute).
    ///
    /// Why it is not pulled with transferFrom: the agreement would then have to
    /// issue an allowance, and on a failed call it would be left hanging — exactly
    /// the defect that had to be fixed in the treasury. A push transfer (Agreement itself
    /// calls transfer(), the diamond does not pull with transferFrom) leaves no
    /// allowance at all — and that does not depend on what comes first, the credit
    /// or the transfer (today the credit comes first, see the comment above).
    ///
    /// The trust here is exactly the same as in updateStatus and notifyArbiterTimeout:
    /// the caller must be a registered agreement, and only the factory can
    /// register one.
    ///
    /// There is NO arbiter-address argument (and accepting one would not be right):
    /// claimDispute() always sets the diamond itself as the arbiter IN THE AGREEMENT
    /// (setArbiter(address(this)), Diamond-as-arbiter), so Agreement.arbiter
    /// is always either 0 or the diamond's address, never a person. Accepting it as
    /// a parameter would mean burning 80% of every fee on an arbiter who
    /// has no way to call withdrawArbiterReward() in their own name (that one reads
    /// _msgSender(), and there is nothing to make the diamond call itself with).
    ///
    /// The source of the real arbiter is pendingVerdicts[msg.sender].arbiter and NOT
    /// disputeClaims[msg.sender]. Both fields are written in step (submitVerdict
    /// requires caller == disputeClaims[agreement]) and cannot diverge before
    /// finalization — but at the moment Agreement actually calls this
    /// function (from inside finalizeVerdict → agreement.call(resolveDispute)),
    /// the guarantee at pendingVerdicts is the stronger one: finalizeVerdict already requires
    /// v.submittedAt != 0 (otherwise revert NoVerdict before the call) and holds
    /// v.executing = true for the whole external call — it is precisely executing==true
    /// that stops clearDisputeClaim() from deleting pendingVerdicts in this window (this is not
    /// the only place able to delete the record — clearStuckVerdict does the same
    /// WITHOUT the !v.executing check; its gate
    /// require(status != DISPUTED) is by itself no protection here — resolvedAt
    /// is already set by this moment (in Agreement, before the call), so
    /// status() inside this window would already return RESOLVED rather than DISPUTED, and
    /// the gate would LET IT THROUGH. Wedging in is impossible for another reason: the whole
    /// window — from resolvedAt to this call — lies inside one atomic
    /// transaction (finalizeVerdict → agreement.call(resolveDispute) →
    /// creditDisputeFee), while clearStuckVerdict is a separate call from the owner,
    /// which simply has nowhere to run between the steps of someone else's transaction).
    /// disputeClaims has no such protection: clearDisputeClaim() clears it
    /// unconditionally, so its integrity here would depend on Agreement
    /// transferring the fee and calling this function strictly before _clearDisputeClaim() —
    /// that is, on the order of code in someone else's function rather than on an invariant here.
    /// pendingVerdicts.arbiter does not depend on that order under any circumstances.
    function creditDisputeFee(uint256 total) external {
        if (RegistryStorage.store().agreements[msg.sender].client == address(0))
            revert NotRegisteredAgreement();
        if (total == 0) revert ZeroAmount();

        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        LegacyArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[msg.sender];

        address arbiter_ = v.arbiter;
        // Nobody carried the dispute through to a verdict (submitVerdict was never called) — there
        // is nobody to credit, and silence is not allowed: money without an addressee would hang
        // in the contract without a single counter pointing at it.
        if (arbiter_ == address(0)) revert NoVerdictSubmitted();

        uint256 toArbiter;
        uint256 toTreasury;
        if (v.overturned) {
            // The verdict was overturned (overturnVerdict/resolveAppeal) — the arbiter was wrong,
            // there will be no reward, the whole fee goes to the treasury. Symmetrically to the way
            // finalizeVerdict on an overturn does not give the arbiter the top-up either but
            // returns it to the payer through refundableBounty (see the top-up refund
            // block inside finalizeVerdict, above in this file).
            // An earlier note here pointed at a payout from the bank for a dispute — that block is
            // gone, the flat payout was taken out entirely.
            toTreasury = total;
        } else {
            toArbiter = (total * ARBITER_SHARE_BPS) / 10_000;
            // By subtraction rather than a second share: this way not a single unit is lost to
            // rounding and the parts always add up to the whole.
            toTreasury = total - toArbiter;
        }

        d.arbiterRewards[arbiter_] += toArbiter;
        d.treasurySlice            += toTreasury;

        emit DisputeFeeCredited(arbiter_, toArbiter, toTreasury);
    }

    /// @notice Send the accumulated treasury share to the current fee recipient.
    ///
    /// Deliberately open: the money goes only to the address from
    /// FactoryStorage.feeRecipient, so the right to call decides nothing, while
    /// openness means the payout does not depend on whether the owner
    /// remembers it, and a keeper can push it through.
    function withdrawTreasurySlice() external {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        uint256 slice = d.treasurySlice;
        if (slice == 0) revert NothingToPush();

        d.treasurySlice = 0;

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        address recipient = fs.feeRecipient;
        bool ok = ILegacyUSDCFull(fs.usdc).transfer(recipient, slice);
        require(ok, "ArbiterRegistry: treasury slice transfer failed");

        emit TreasurySlicePushed(recipient, slice);
    }

    function getTreasurySlice() external view returns (uint256) {
        return LegacyArbiterRegistryStorage.data().treasurySlice;
    }

    /// @notice Top up the arbiter bank. Besides the owner this can be done by
    /// the current fee recipient (`FactoryStorage.feeRecipient`) — which the treasury
    /// becomes when it is put there by a `setFeeRecipient` call.
    ///
    /// There is deliberately no separate field for the treasury address: there is one source
    /// of truth, and replacing the treasury carries this right over by itself, nothing to forget.
    /// If the fee recipient is an ordinary wallet (as it was before the treasury), it
    /// gains the right to put its own money into the bank. That is a donation, not a risk.
    function fundVault(uint256 amount) external {
        if (msg.sender != OwnershipLib.contractOwner()
            && msg.sender != FactoryStorage.store().feeRecipient) revert NotOwnerOrFeeRecipient();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        address usdc = FactoryStorage.store().usdc;
        bool ok = ILegacyUSDCFull(usdc).transferFrom(msg.sender, address(this), amount);
        require(ok, "ArbiterRegistry: USDC transfer failed");
        d.vaultBalance += amount;
        emit VaultFunded(msg.sender, amount);
    }

    /// @notice Disabled on 31 July 2026. The flat payout from the bank was rejected
    /// by the design of 28 July, but the code did not follow: the credit lived
    /// in parallel with the 80% of the fee and was switched on by a single call from the owner.
    /// With the arrival of the top-up there would have been three sources.
    ///
    /// The function is not deleted but reverts: eight historical scripts in script/
    /// name its selector in their mounting lists, forge build compiles
    /// the whole folder, and deleting it would break the build. Those scripts are
    /// records of upgrades that happened, and broadcast/ is gitignored, so their sources
    /// are the only remaining record. A reverting setter is more honest than a working one
    /// that writes a value nobody reads.
    function setRewardPerDispute(uint256) external pure {
        revert RewardPathRetired();
    }

    /// @notice How much the arbiter must receive for a dispute in total.
    /// A stored field rather than a constant: the right price of human time
    /// cannot be guessed in advance, and changing it later must take one transaction, without
    /// an upgrade. The start is 10 USDC.
    function setArbiterFloor(uint256 amount) external onlyOwner {
        LegacyArbiterRegistryStorage.data().arbiterFloor = amount;
        emit ArbiterFloorUpdated(amount);
    }

    // -------- PAID CALL FOR AN ARBITER: PAYMENT AND REFUND --------

    /// @notice Top up to the threshold so that an arbiter takes the dispute.
    ///
    /// There is no need to build a separate "call an arbiter": the voluntary claim already
    /// works, it simply does not fire on a small pot. Money at stake is
    /// the only thing it lacks.
    ///
    /// The party that needs a judge pays, not the common bank. That is the protection
    /// against farming: putting up an arbiter of one's own means paying oneself.
    ///
    /// The sender is taken through _msgSender() and not msg.sender: the client calls this
    /// function ONLY through the ERC-2771 forwarder,
    /// and on that path msg.sender is the forwarder's address. With a direct msg.sender
    /// the party check would reject every payment, and the payer in
    /// storage and in the event would turn out to be the forwarder rather than the person.
    function fundDispute(address agreement) external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();

        RegistryStorage.AgreementRecord storage rec = RegistryStorage.store().agreements[agreement];
        if (rec.client == address(0)) revert NotAuthorized();
        if (caller != rec.client && caller != rec.executor) revert NotParty();

        if (d.disputeClaims[agreement] != address(0)) revert DisputeAlreadyClaimed();
        if (d.disputeBounty[agreement] != 0) revert BountyAlreadyFunded();

        uint256 need = quoteDisputeTopUp(agreement); // reverts NotDisputed if there is no dispute

        // The same gate as in claimDispute (the DisputeWindowPassed check after
        // disputedAt()/DISPUTE_WINDOW()), and the same comparison:
        // after disputedAt + DISPUTE_WINDOW a dispute can be neither claimed nor
        // judged (submitVerdict also hits DisputeWindowPassed), and the status
        // stays DISPUTED until somebody pulls the timeout. Taking
        // money for a judge who physically can no longer exist is not allowed:
        // it would not be lost (it comes back on the timeout), but it would freeze until
        // somebody else acts, and the service would not be rendered at all.
        (bool dOk, bytes memory dData) = agreement.staticcall(abi.encodeWithSignature("disputedAt()"));
        require(dOk, "ArbiterRegistry: disputedAt read failed");
        (bool wOk, bytes memory wData) = agreement.staticcall(abi.encodeWithSignature("DISPUTE_WINDOW()"));
        require(wOk, "ArbiterRegistry: DISPUTE_WINDOW read failed");
        if (block.timestamp > abi.decode(dData, (uint256)) + abi.decode(wData, (uint256))) {
            revert DisputeWindowPassed();
        }

        if (need == 0) revert TopUpNotNeeded();

        d.disputeBounty[agreement]      = need;
        d.disputeBountyPayer[agreement] = caller;

        address usdc = FactoryStorage.store().usdc;
        bool ok = ILegacyUSDCFull(usdc).transferFrom(caller, address(this), need);
        require(ok, "ArbiterRegistry: bounty transfer failed");

        emit DisputeBountyFunded(agreement, caller, need);
    }

    function getDisputeBounty(address agreement) external view returns (uint256) {
        return LegacyArbiterRegistryStorage.data().disputeBounty[agreement];
    }

    /// @notice Collect a top-up that could not be returned by a push.
    /// Exists for USDC blacklists: the refund inside clearDisputeClaim is
    /// deliberately soft, because that path is wrapped in a swallowing catch.
    ///
    /// _msgSender() and not msg.sender, for the same reason as in fundDispute:
    /// the call arrives through the forwarder, and with a direct msg.sender a person would collect
    /// not their own remainder but the (always zero) remainder of the forwarder.
    function withdrawDisputeBounty() external {
        address caller = _msgSender();
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        uint256 amount = d.refundableBounty[caller];
        if (amount == 0) revert NoRefundableBounty();
        d.refundableBounty[caller] = 0;
        address usdc = FactoryStorage.store().usdc;
        bool ok = ILegacyUSDCFull(usdc).transfer(caller, amount);
        require(ok, "ArbiterRegistry: bounty withdrawal failed");
        emit DisputeBountyWithdrawn(caller, amount);
    }

    function getRefundableBounty(address who) external view returns (uint256) {
        return LegacyArbiterRegistryStorage.data().refundableBounty[who];
    }

    function setDAOAddress(address dao) external onlyOwner {
        if (dao == address(0)) revert ArbiterZeroAddress();
        LegacyArbiterRegistryStorage.data().daoAddress = dao;
        emit DAOAddressSet(dao);
    }

    // -------- AGREEMENT CALLBACKS --------

    function clearDisputeClaim(address agreement) external {
        require(msg.sender == agreement, "ArbiterRegistry: only agreement");
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        address claimedArbiter = d.disputeClaims[agreement];
        if (claimedArbiter != address(0)) {
            // The anchor and the silence record are not touched — see releaseDisputeClaim.
            delete d.disputeClaims[agreement];
            if (d.openClaimCount[claimedArbiter] > 0) d.openClaimCount[claimedArbiter]--;
        }
        // Auto-cleanup of a stuck verdict: if Agreement left the dispute through a timeout,
        // while the verdict is not yet finalized and is not executing right now — delete it.
        LegacyArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];
        if (v.submittedAt > 0 && !v.finalized && !v.executing) {
            delete d.pendingVerdicts[agreement];
            emit StuckVerdictAutoCleared(agreement);
        }

        // Refund of the top-up if no verdict happened.
        //
        // The discriminator already exists and a second one is not needed: finalizeVerdict
        // sets v.executing before calling resolveDispute and clears it after, while
        // v.finalized is set LATER than the external call — that is, here it is still false.
        // So executing == true means "this is inside the finalization of a verdict", and
        // it is set only on that path; on both timeout branches it is false.
        //
        // Selling what cannot be guaranteed is worse than not selling:
        // paid and got neither a judge nor the money back — that is no longer a service.
        if (!v.executing) {
            // A counter for both: the dispute ended, there was nobody or no time to judge.
            // Written straight into the namespaced reputation storage — the same device
            // this file already uses to reset XP on demotion
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

                // A soft refund. A hard one is inadmissible here: Agreement calls this
                // function inside a `try {} catch {}` with an empty handler
                // (Agreement._clearDisputeClaim), so a revert of the transfer would drag down
                // the release of the claim and the decrement of openClaimCount — silently, and the arbiter
                // would be left forever with an unclosed dispute.
                //
                // The length of the response is checked explicitly, by the same device as
                // SafeUSDC.trySafeTransfer in Agreement: abi.decode
                // panics by itself on a response of 1 to 31 bytes, and then the "soft"
                // refund would turn out just as hard as an ordinary one, in exactly
                // the branch that is deliberately made soft.
                address usdc = FactoryStorage.store().usdc;
                (bool ok, bytes memory ret) = usdc.call(
                    abi.encodeWithSelector(ILegacyUSDCFull.transfer.selector, payer, bounty)
                );
                bool delivered;
                if (ok) {
                    if (ret.length == 0) delivered = true;
                    else if (ret.length >= 32) delivered = abi.decode(ret, (bool));
                    // ret.length in 1..31 — delivered stays false, decode is not called.
                }
                if (delivered) {
                    emit DisputeBountyRefunded(agreement, payer, bounty);
                } else {
                    d.refundableBounty[payer] += bounty;
                    emit DisputeBountyRefundable(agreement, payer, bounty);
                }
            }
        }
    }

    /// @notice Emergency cleanup of a stuck pending verdict.
    /// Arises when triggerArbiterTimeout executes Agreement before finalizeVerdict —
    /// Agreement goes to REFUNDED while pendingVerdicts hangs forever.
    function clearStuckVerdict(address agreement) external {
        if (msg.sender != OwnershipLib.contractOwner()) revert NotOwner();
        if (agreement == address(0)) revert ArbiterZeroAddress();
        // Make sure Agreement is already in a terminal state (not DISPUTED = 4)
        (bool ok, bytes memory st) = agreement.staticcall(abi.encodeWithSignature("status()"));
        require(ok, "ArbiterRegistry: status read failed");
        require(abi.decode(st, (uint8)) != 4, "ArbiterRegistry: agreement still disputed");
        delete LegacyArbiterRegistryStorage.data().pendingVerdicts[agreement];
    }

    // -------- VIEWS --------

    function isDaoActive() public view returns (bool) {
        if (LegacyArbiterRegistryStorage.data().daoActiveManual) return true;
        return ReputationStorage.data().uniqueActiveUsers >= DAO_THRESHOLD;
    }

    function getMinXPToRegister() external pure returns (uint256) { return MIN_XP_TO_REGISTER; }
    function getDaoThreshold()    external pure returns (uint256) { return DAO_THRESHOLD; }

    function getChiefArbiter()  external view returns (address) { return LegacyArbiterRegistryStorage.data().chiefArbiter; }
    function isRegisteredArbiter(address addr) external view returns (bool) { return LegacyArbiterRegistryStorage.data().isArbiter[addr]; }
    function getArbiters()      external view returns (address[] memory) { return LegacyArbiterRegistryStorage.data().arbiterList; }
    function getDisputeClaimer(address agreement) external view returns (address) { return LegacyArbiterRegistryStorage.data().disputeClaims[agreement]; }

    /// @notice When the CURRENT claimer took this dispute, in block seconds. If they
    /// took it several times — the moment of the last claim, and the floor is counted from it.
    /// 0 — the dispute is not claimed (including released) or was claimed before this field existed.
    ///
    /// The signature is deliberately single-part: the asker needs the anchor of whoever
    /// judges the dispute now, not a history per arbiter. The history exists, it is in
    /// the DisputeClaimed/DisputeReleased events.
    function getDisputeClaimedAt(address agreement) external view returns (uint256) {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        return d.disputeClaimedAtBy[agreement][d.disputeClaims[agreement]];
    }

    /// @notice When the current claimer recorded "asked, no answer". 0 — did not record.
    /// Zero here also means "the dispute is ownerless": the record belongs to the arbiter, not
    /// to the deal, and it leaves the view together with the claim without leaving the chain.
    function getNoResponseAt(address agreement) external view returns (uint256) {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        return d.disputeNoResponseAtBy[agreement][d.disputeClaims[agreement]];
    }

    /// @notice How much must pass from the claim of a dispute to the silence record.
    /// The client must ask here rather than keep a number of its own.
    function getNoResponseFloor() external pure returns (uint256) {
        return NO_RESPONSE_FLOOR;
    }

    /// @notice All presentation digests for a deal, in the order they appeared.
    /// The order is the content of the answer: a dispute is decided by what landed first.
    ///
    /// Convenient and honest on ordinary numbers, but the whole list on a large
    /// count runs into the gas ceiling of eth_call — and reading breaks FOR THE
    /// ARBITER and for the other party, not for whoever inflated the list. Whoever needs a
    /// guarantee has getPresentationDigestsPage below. Who exactly put each
    /// digest there is not visible here: that is in the PresentationDigestRecorded event, and
    /// the block number is fetched from there too.
    function getPresentationDigests(address agreement) external view returns (bytes32[] memory) {
        return LegacyArbiterRegistryStorage.data().presentationDigests[agreement];
    }

    /// @notice Digests for a deal by window: from `offset`, no more than `limit` of them.
    /// @dev The full getPresentationDigests is honest on small numbers, but on a large
    /// list it runs into the eth_call ceiling — and reading breaks FOR THE ARBITER, not for
    /// whoever inflated the list. A window gives the reader a way out without a contract upgrade.
    ///
    /// ⚠️ On an honest request it NEVER reverts: the reader is not obliged to know
    /// the length in advance, and can learn it only with a second call — that is, in
    /// another block, when the length is already different. A revert on "offset past the end"
    /// would mean whoever pages must win the race against whoever writes. Therefore:
    ///   - `offset` past the end of the list (and an empty list) → an empty array;
    ///   - `limit == 0`                                          → an empty array;
    ///   - `offset + limit` greater than the length              → the tail to the end.
    /// An empty answer reads unambiguously: "there is nothing more here", and that is
    /// the stopping condition for whoever pages. Telling it apart from "off target" is possible
    /// with getPresentationDigestCount, but usually pointless.
    ///
    /// The sum `offset + limit` is deliberately computed nowhere, and this is not
    /// a nitpick: under the checked arithmetic of 0.8 a naive `offset + limit` with a
    /// `limit` like type(uint256).max PANICS (0x11), that is, it breaks exactly
    /// the promise "it does not revert on an honest request" — and "give me everything from
    /// "this point" is an honest request. Measured by mutation: the naive sum → the red test
    /// test_Page_HugeLimit_IsUpToTheEnd_NotARevert with panic 0x11.
    function getPresentationDigestsPage(address agreement, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory)
    {
        bytes32[] storage all = LegacyArbiterRegistryStorage.data().presentationDigests[agreement];
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

    /// @notice How many digests lie against a deal. Separate from the list — so that
    /// a screen that only needs "any or none" does not drag the whole array.
    function getPresentationDigestCount(address agreement) external view returns (uint256) {
        return LegacyArbiterRegistryStorage.data().presentationDigests[agreement].length;
    }

    /// The public halves of the arbiter's chat keys. Zeros mean "there are no keys" —
    /// for the client that is the sign "there is nobody to present to", and telling "no entry"
    /// from "a zero was written" is pointless: a zero key is forbidden on write.
    ///
    /// ⚠️ The converse is not true: a non-zero key does NOT mean "an acting arbiter".
    /// The key is not erased on loss of status (removeArbiter/resignAsArbiter/
    /// demotion) — see the warning in setArbiterChatKey. The status is read
    /// separately, through isRegisteredArbiter, and is not inferred from the presence of a key.
    function getArbiterChatKeys(address arbiter)
        external
        view
        returns (bytes32 boxKey, bytes32 signKey)
    {
        LegacyArbiterRegistryStorage.Data storage d = LegacyArbiterRegistryStorage.data();
        return (d.arbiterBoxKey[arbiter], d.arbiterSignKey[arbiter]);
    }
    function getArbiterDeals(address arbiter) external view returns (address[] memory) { return LegacyArbiterRegistryStorage.data().arbiterDeals[arbiter]; }
    function getClaimCommitment(bytes32 c) external view returns (uint256) { return LegacyArbiterRegistryStorage.data().claimCommitments[c]; }

    function getPendingVerdict(address agreement) external view returns (LegacyArbiterRegistryStorage.PendingVerdict memory) {
        return LegacyArbiterRegistryStorage.data().pendingVerdicts[agreement];
    }

    function getArbiterReward(address arbiter) external view returns (uint256) { return LegacyArbiterRegistryStorage.data().arbiterRewards[arbiter]; }
    function getVaultBalance()  external view returns (uint256) { return LegacyArbiterRegistryStorage.data().vaultBalance; }
    /// @notice The path was taken out on 31 July 2026 (see setRewardPerDispute) — the field
    /// this function reads is no longer written by anyone, the value is always 0.
    function getRewardPerDispute() external view returns (uint256) { return LegacyArbiterRegistryStorage.data().rewardPerDispute; }
    function getDAOAddress()    external view returns (address) { return LegacyArbiterRegistryStorage.data().daoAddress; }

    /// @notice Public (not external), because quoteDisputeTopUp calls it
    /// directly — the default on zero is substituted in one place, not two.
    function getArbiterFloor() public view returns (uint256) {
        uint256 f = LegacyArbiterRegistryStorage.data().arbiterFloor;
        return f == 0 ? DEFAULT_ARBITER_FLOOR : f;
    }
    function getArbiterMistakeStreak(address addr) external view returns (uint256) { return LegacyArbiterRegistryStorage.data().arbiterMistakeStreak[addr]; }
    function hasSubmittedVerdict(address agreement) external view returns (bool) {
        return LegacyArbiterRegistryStorage.data().pendingVerdicts[agreement].submittedAt != 0;
    }
    function getAppealVotes(address agreement) external view returns (uint256 uphold, uint256 overturnVotes) {
        LegacyArbiterRegistryStorage.PendingVerdict storage v = LegacyArbiterRegistryStorage.data().pendingVerdicts[agreement];
        return (v.votesUphold, v.votesOverturn);
    }

    function hasVotedOnAppeal(address agreement, address arbiterAddr) external view returns (bool) {
        return LegacyArbiterRegistryStorage.data().hasVotedAppeal[agreement][arbiterAddr];
    }
    function getArbiterBond(address addr) external view returns (uint256) { return LegacyArbiterRegistryStorage.data().arbiterBond[addr]; }
    function getOpenClaimCount(address addr) external view returns (uint256) { return LegacyArbiterRegistryStorage.data().openClaimCount[addr]; }

    /// @notice How much must be topped up for the arbiter to receive the threshold in total.
    /// Returns 0 if the pot is already large enough — then the top-up button
    /// should not be shown at all.
    ///
    /// The fee is taken FROM THE DEAL by a disputeFee() call rather than recomputed here.
    /// The fee formula (3% with a ceiling) lives in Agreement, and a second copy in the
    /// facet would diverge from it at the very first edit — silently, because the
    /// divergence is visible only to whoever compares the number shown with the one that
    /// arrived in the wallet.
    function quoteDisputeTopUp(address agreement) public view returns (uint256) {
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

        return arbiterGets >= floor_ ? 0 : floor_ - arbiterGets;
    }
}
