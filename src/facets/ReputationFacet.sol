// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ReputationFacet.sol
//
// On-chain XP system. Users claim XP once a deal is finished.
// Anti-gaming: deal >= 10 USDC, cap of 3 wins per pair of addresses.
// uniqueActiveUsers — count of distinct addresses with XP > 0 (the DAO trigger).
//
// ⚠️ PHASE 2 WAS DELETED ON 20 SEPTEMBER 2026, AND IT WAS A BRAKE ON A ROAD
// THAT NO LONGER LEADS ANYWHERE. It read: past 1000 XP a client earned nothing
// at all, and an executor earned only while an unbroken streak stood behind
// him. Its whole purpose was to slow the climb toward the 3000 XP that used to
// open the arbiter corps — so that nobody could buy a seat with one large deal.
// The corps no longer asks for XP, so there is nothing left to slow down, and
// what remained was a rule that silently stopped a person's standing from
// growing and told them nothing about why.
//
// What still holds the number honest: the 10 USDC floor under a deal, the cap
// of 3 counted wins per pair, the 300-point ceiling on volume XP, and
// MIN_COUNTERPARTY_WINS — the requirement that the OTHER side of a deal had
// already closed deals of its own before that deal can move a clean streak.
// Those bound what one address can manufacture; Phase 2 only bound how fast an
// honest one could grow.
//
// ⚠️ THAT LAST BAR WAS AN XP NUMBER UNTIL 16 OCTOBER 2026, AND AN XP NUMBER
// CANNOT MEASURE HISTORY. `MIN_COUNTERPARTY_XP = 50` stood here with a comment
// calling it the load-bearing number of this file. It was not load-bearing: a
// win pays a flat WIN_XP of 100 on any deal of 10 USDC or more, so ONE deal
// put a counterparty at twice the bar — and volume XP pays `amount / 10 USDC`
// up to MAX_VOLUME_XP, so ANY bar up to WIN_XP + MAX_VOLUME_XP was still
// reachable with ONE deal, by making that deal bigger. The number said
// "standing"; what it measured was the size of a single escrow, whose body
// comes home to whoever paid it.
//
// The gate now counts the thing it was always trying to ask about: how many
// deals the other side has actually closed (`countedWins`, appended to the
// struct below). Size buys nothing, because a win is one win whether the deal
// was 10 USDC or 10,000.
// ============================================================

import "../RegistryFacet.sol"; // RegistryStorage — for verifying agreements
import "../FactoryFacet.sol";   // FactoryStorage — for the trusted forwarder

interface IAgreementView {
    function status()           external view returns (uint8);
    function amount()           external view returns (uint256);
    function client()           external view returns (address);
    function executor()         external view returns (address);
    function clientWonDispute() external view returns (bool);
}

// ---------- STORAGE ----------

library ReputationStorage {
    /// @custom:storage-location erc7201:hexseal.reputation.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.reputation.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant POSITION = 0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400;

    struct Data {
        mapping(address => uint256) xp;
        mapping(address => uint256) volumeXPAccrued;   // for the MAX_VOLUME_XP cap per address
        mapping(address => bool)    clientClaimed;     // agreement → the client already claimed XP
        mapping(address => bool)    executorClaimed;   // agreement → the executor already claimed XP
        mapping(address => bool)    pairCounted;       // agreement → the pair is already assessed (first claimer)
        mapping(address => bool)    dealIsWin;         // agreement → the deal counted as a win
        mapping(bytes32 => uint256) pairWins;          // keccak(sortedPair) → number of wins
        mapping(address => bool)    hasEarnedXP;       // for uniqueActiveUsers
        uint256                     uniqueActiveUsers;
        mapping(address => uint256) cleanStreak;        // executor → consecutive clean (dispute-free) closes
        mapping(address => bool)    streakEvaluated;    // agreement → cleanStreak already updated for this deal
        // ── Disputes that ended without a verdict ──
        // Counted for BOTH participants. Statistics, not a verdict: on a 50/50
        // split nobody established who was at fault, and a griefer who responds
        // neatly looks exactly like an honest party. Show it as a share of the
        // deal count — one dispute in fifty is noise, eight in ten a portrait.
        mapping(address => uint256) unresolvedDisputes;
        // ── Clean closes that moved nothing, and why anyone can see them ──
        // APPENDED to the end of the struct on 20 September 2026 — nothing
        // above this line was reordered, retyped or removed, because this
        // namespace is live on Base Sepolia and a clone reads it by slot.
        //
        // Counts, per executor, the deals that finished COMPLETED and did NOT
        // advance the clean streak because the counterparty had closed fewer
        // than MIN_COUNTERPARTY_WINS counted deals before them. (It was an XP
        // bar when this field was written and became a count of deals on
        // 16 October 2026; the counter does not distinguish the two eras, and
        // nothing stored here needed to change when the bar did.) The rule
        // itself is old; until this field it was enforced in COMPLETE SILENCE — no event, no read, no
        // screen — so a person could work for a year with newcomers, believe a
        // streak was accumulating, and hold zero. That became a lie the day the
        // streak turned into the ONLY door into the arbiter corps.
        //
        // A counter rather than only a log, deliberately: a log needs an indexer
        // and a backfill to be read, and this number has to survive a page
        // reload on a wallet nobody has indexed. The log is emitted too
        // (CleanStreakEvaluated) — it carries the per-deal reason, this carries
        // the running total.
        mapping(address => uint256) streakStalls;
        // ── What a streak costs to manufacture, and the two fields that answer
        //    it (the owner's decision of 12 October 2026) ──
        //
        // APPENDED TO THE END on 12 October 2026. Nothing above this line was
        // reordered, retyped or removed: this namespace is live on Base Sepolia
        // and is read by slot, so appending is the only legal move. Same
        // argument as `streakStalls` above, written out there at length.
        //
        // ⚠️ THE HOLE THESE TWO CLOSE WAS PRICED AT SIX DOLLARS. The entrance to
        // the arbiter corps asks for a clean streak of five and nothing else.
        // Each of the two rules guarding that streak is sound ALONE, and the
        // hole was in their product: XP is awarded to BOTH sides of a deal, and
        // a streak advanced when the counterparty already held 50 XP
        // (`MIN_COUNTERPARTY_XP`, the bar that stood here until 16 October
        // 2026). So one pair of wallets could pay for ONE $10 deal to put
        // 100 XP on the "client", then run five more deals at the $1 fee floor
        // against that same now-respectable address — five ticks, six dollars,
        // one seat. Nothing in the protocol made a deal take any time either,
        // so the whole run fits in seconds.
        //
        // ⚠️ THAT PRODUCT IS WHERE THE 16 OCTOBER 2026 CHANGE CAME FROM. The
        // distinct-client rule below made the run cost five primed clients
        // instead of one; the bar itself was still one deal per client, because
        // one win pays twice 50 XP. Counting DEALS instead of points makes it
        // two deals per client, and no deal size shortens that.
        //
        //   streakClientCounted  executor -> client -> this client has already
        //     moved this executor's streak once. A SECOND deal with the same
        //     client is still perfectly legal and still pays XP in full — it
        //     simply buys no tick. The owner was explicit about why: "if you
        //     block the point of dealing with somebody more than once, then a
        //     repeat client is never reachable". The streak counts DISTINCT
        //     clients; it has never counted deals.
        //
        //     ⚠️ Never cleared, not even when the streak resets. Clearing it
        //     would hand a reset executor his old client list back to re-farm,
        //     which is the same hole with one dispute in front of it.
        //
        //   streakClockStartedAt  executor -> when the clock under the CURRENT
        //     run started: the timestamp of the first advancing tick taken
        //     while this field stood at zero. Zeroed EVERYWHERE the streak is
        //     zeroed (there are three such places — `_evalStreakOnce`'s lost
        //     dispute, `notifyExecutorFault`, and `_performRemoval` over in
        //     ArbiterAccountabilityFacet), because a date surviving a reset is
        //     worse than no date: it would hand out an instant right to judge
        //     on the strength of a run that no longer exists.
        //
        // ⚠️ NEITHER FIELD CHANGES WHAT A STREAK MEANS. It stays a plain count
        // that `getCleanStreak`, the application mirrors and the handover gate
        // all read as before. The TIME rule is enforced at the door it guards
        // (`ArbiterRegistryFacet.applyAsArbiter`) and not here, so none of those
        // readers had to learn a new meaning for an old number.
        mapping(address => mapping(address => bool)) streakClientCounted;
        mapping(address => uint256)                  streakClockStartedAt;
        // ── What the counterparty bar counts now: deals, not points ──
        //
        // APPENDED TO THE END on 16 October 2026. Nothing above this line was
        // reordered, retyped or removed: this namespace is live on Base Sepolia
        // and is read by slot, so appending is the only legal move. The same
        // argument as `streakStalls` and the two fields above, written out
        // there at length.
        //
        // countedWins  address -> how many agreements this address was a party
        //   to that were COUNTED AS A WIN AND WERE FOUND THROUGH A BOARD.
        //   "Counted as a win" is not a second definition invented here: it is
        //   the agreements for which `dealIsWin` was set, so this counter is
        //   incremented at that one site (`_evalPairCap`) and nowhere else. A
        //   second test of the same idea written somewhere else would drift
        //   away from the first in silence, and the two would then disagree
        //   about a specific deal with nothing to say which was right.
        //
        //   It therefore inherits, deliberately, everything `dealIsWin` means:
        //   the 10 USDC floor, and the cap of MAX_WINS_PAIR counted wins per
        //   pair of addresses — so a pair that has used its three cannot mint a
        //   fourth for either side. It is incremented for BOTH parties, because
        //   `dealIsWin` is a fact about the DEAL and not about who did better
        //   out of it. A dispute the executor lost still counts for him: it was
        //   a real deal with real money and a real fee, and it cost him XP on
        //   top. Counting it makes the bar no cheaper, which is the only
        //   property the bar needs.
        //
        //   ⚠️ AND SINCE 16 OCTOBER 2026 IT ALSO ASKS WHERE THE DEAL CAME FROM
        //   (the owner's decision: the streak and the win count work only on
        //   deals the board made). `dealIsWin` is still set on a direct hire —
        //   it is what pays the XP, and XP is not touched by any of this — but
        //   the two increments here stand inside a second test,
        //   `DealOriginStorage.bornOnBoard[agreement]`. So `countedWins` is no
        //   longer a synonym for `dealIsWin`, and nothing should read it as
        //   one: it is the board's half of the win count, which is exactly the
        //   half the counterparty bar in `_evalStreakOnce` is asking about.
        //
        // ⚠️ IT STARTS AT ZERO FOR EVERY ADDRESS THAT ALREADY EXISTS, and that
        // is not a migration that was skipped — there is nothing to migrate
        // from. Deals settled before this field existed were never counted
        // anywhere, exactly as `streakStalls` says about its own history. So on
        // the day this ships, every address on the chain reads as having closed
        // nothing, and the first streak tick anybody earns comes after his
        // client has closed two more deals of 10 USDC or more. The price is two
        // deals per counterparty, paid once, and it is paid by honest users
        // too.
        //
        // ⚠️ NOBODY'S RECORDED STREAK IS RECALCULATED. `cleanStreak` is a
        // stored counter, not a view over history: ticks already earned stand,
        // and this change takes none of them away. The same treatment the
        // 12 October 2026 rules gave a streak that was already standing — see
        // `streakClockStartedAt`, where a run with no recorded start is neither
        // credited retroactively nor shut out.
        mapping(address => uint256) countedWins;
    }

    function data() internal pure returns (Data storage d) {
        bytes32 pos = POSITION;
        assembly { d.slot := pos }
    }
}

// ---------- FACET ----------

contract ReputationFacet {

    // -------- CONSTANTS --------

    uint256 private constant WIN_XP               = 100;
    uint256 private constant LOSS_XP_PENALTY       = WIN_XP / 2; // losing a dispute costs half the XP a win would have given — a real signal, not a fatal one
    uint256 private constant MIN_WIN_AMOUNT        = 10_000_000; // 10 USDC (6 decimals)
    uint256 private constant MAX_WINS_PAIR         = 3;
    uint256 private constant MAX_VOLUME_XP         = 300;
    /// A deal moves the executor's clean streak only if the OTHER side had
    /// already closed this many counted deals BEFORE it — not counting the deal
    /// being settled. It is what stops a ring of fresh wallets running a streak
    /// up on each other for nothing, and with the streak the only door into the
    /// arbiter corps it is the load-bearing number of this file.
    ///
    /// ⚠️ TWO, AND WHY A COUNT RATHER THAN A SCORE (16 October 2026). The bar
    /// here was `MIN_COUNTERPARTY_XP = 50` and the comment above it said the
    /// same load-bearing words. The number was wrong in kind, not in size: a
    /// win pays a flat WIN_XP on any deal at or above MIN_WIN_AMOUNT, so one
    /// 10 USDC deal left a counterparty at twice the bar, and volume XP pays
    /// `amount / MIN_WIN_AMOUNT` up to MAX_VOLUME_XP, so raising the bar bought
    /// nothing either — every value up to WIN_XP + MAX_VOLUME_XP stayed
    /// reachable with a SINGLE deal, by making that deal bigger. A gate on
    /// points was a gate on the size of one escrow, and the escrow comes home.
    ///
    /// Two is the smallest number that says "more than once". One would be
    /// satisfied by the same single deal the old bar was satisfied by.
    ///
    /// ⚠️ WHAT IT COSTS TO BUY, AS A NUMBER, because every lever in this
    /// project is priced. A counted win needs a deal of at least
    /// MIN_WIN_AMOUNT, and the fee on such a deal is the fee floor, so making
    /// one address eligible as a counterparty costs two fee floors instead of
    /// one. The whole streak needs five distinct such clients. The bodies of
    /// the escrows come home in both cases; what changed is that the bill can
    /// no longer be shortened by making a deal bigger, and that is the whole
    /// of what a count buys over a score. Nobody should read this door as
    /// unbuyable — the span rule at the entrance is the half that cannot be
    /// paid for.
    ///
    /// ⚠️ It is also the number that used to be invisible. See streakStalls in
    /// the struct above and CleanStreakEvaluated below: every deal that fails
    /// this test says so out loud and carries the count the refusal was
    /// actually made on, so "why did my streak not move" has an answer that
    /// does not require reading this source.
    ///
    /// ⚠️ NOT MIRRORED ANYWHERE. `getStreakStanding` hands it out with the two
    /// numbers it explains, so a screen reads it and does not keep a copy.
    uint256 private constant MIN_COUNTERPARTY_WINS = 2;

    // PHASE2_XP_THRESHOLD (1000) and CLEAN_STREAK_REQUIRED (10) were deleted on
    // 20 September 2026 together with the gate they fed — see the file header.
    // MIN_COUNTERPARTY_XP (50) was deleted on 16 October 2026 with the gate IT
    // fed, and for the same reason rather than out of tidiness: a bar left
    // standing as decoration while a different bar does the deciding is worse
    // than either alone, because a reader who finds it believes he has found
    // the rule. None of the three is "kept as an anchor for the future": an
    // unread constant is a number that drifts in silence, and this file has
    // said so before about a neighbour's mirror.

    // Agreement.sol 7-state enum
    uint8 private constant STATUS_COMPLETED = 3;
    uint8 private constant STATUS_RESOLVED  = 5;

    // -------- EVENTS --------

    event XPClaimed(address indexed agreement, address indexed claimant, uint256 xpGained);
    event XPPenalized(address indexed agreement, address indexed loser, uint256 xpLost);

    /// A cleanly closed deal's escrow was added to the protocol's settled
    /// volume — the counter the growing deal cap is computed from.
    ///
    /// ⚠️ CARRIES THE RUNNING TOTAL, not just the delta. The cap is a share of
    /// that total, so anybody watching the ceiling move has to be able to
    /// follow the number it is a share of without replaying every event since
    /// the first deal. Emitted only when the volume actually moved: a deal that
    /// ends RESOLVED trips the latch and emits nothing, which is what tells a
    /// reader of the log that a disputed deal bought no ceiling.
    event SettledVolumeCounted(address indexed agreement, uint256 amount, uint256 total);

    /// What a finished deal did to the executor's clean streak, and WHY.
    ///
    /// Emitted exactly once per deal, from the same one-shot branch that moves
    /// the streak (`_evalStreakOnce`), so the log and the stored number can
    /// never disagree about a deal. `streak` is the value AFTER the deal —
    /// unchanged is a perfectly ordinary answer and is reported as such.
    /// `counterpartyWins` is how many counted deals the other side had closed
    /// BEFORE this one, which is the whole of the reason in the
    /// CounterpartyTooNew case; it is carried in the log rather than looked up
    /// afterwards because by the time anybody reads this, that count has moved
    /// on.
    ///
    /// ⚠️ THIS FIELD CARRIED XP UNTIL 16 OCTOBER 2026, AND THE POINT OF
    /// CHANGING IT IS THAT A LOG MUST PUBLISH THE NUMBER THAT DECIDED. When the
    /// gate moved from a points bar to a count of deals, a log still printing
    /// the points would have made the screen explain a refusal with a figure
    /// that no longer decides anything — correct about itself, and an answer to
    /// a question nobody asked. The seam is held by
    /// test/CleanStreakSpeaks.t.sol, in a scene where the two numbers are
    /// deliberately far apart, so a log that reverts to the points one is red
    /// rather than plausible.
    ///
    /// ⚠️ THE EVENT SIGNATURE IS UNCHANGED, hence so is its topic: the types
    /// were `(address,address,uint8,uint256,uint256)` and still are. A row
    /// already in the chain's history therefore still decodes, and still means
    /// what it meant when it was written — XP, under the rule of its day. What
    /// a reader cannot do is tell the two eras apart by the shape of the row;
    /// the block number is the only divider, and that is the cost of not
    /// breaking every existing decoder. It is written down here because the
    /// alternative was to be silent about it.
    event CleanStreakEvaluated(
        address indexed executor,
        address indexed agreement,
        StreakOutcome   outcome,
        uint256         streak,
        uint256         counterpartyWins
    );

    // -------- TYPES --------

    /// The five things that can happen to a clean streak when a deal ends.
    /// Named rather than numbered: a reader of the feed should not have to know
    /// that 1 means "your client was too new".
    ///
    /// ⚠️ APPEND ONLY, AND THE ORDER IS LOAD-BEARING. The log carries the
    /// NUMBER; inserting a member in the middle would silently re-label every
    /// row already in the chain's history — "your client was too new" printed
    /// over "you lost a dispute". The fifth member was appended on 12 October
    /// 2026 and the front end's list is held against this body by
    /// frontend/src/lib/arbiterCaseWork.test.ts.
    enum StreakOutcome {
        Advanced,            // closed clean, counterparty had standing — +1
        CounterpartyTooNew,  // closed clean and counted for NOTHING: the counterparty had closed < MIN_COUNTERPARTY_WINS counted deals
        BrokenByLostDispute, // a dispute the executor lost — back to zero
        HeldByWonDispute,    // a dispute the executor won — neither advanced nor broken
        CounterpartyAlreadyCounted // closed clean, XP paid in full, but this client has already moved this streak once
    }

    // -------- ERRORS --------

    error AgreementNotRegistered();
    error DealNotEligible();
    error NotParty();
    error AlreadyClaimed();
    error NotAgreement();

    // -------- ACTIONS --------

    /// @notice Award XP to both sides automatically when a deal finishes.
    /// Called by the Agreement itself through the Diamond (msg.sender == agreement).
    /// Only for COMPLETED and RESOLVED — not for REFUNDED.
    /// On RESOLVED (a dispute) only the winning side gets XP, and the losing side gives
    /// some back: otherwise an executor who failed the deal and lost the arbitration would
    /// gain reputation on a par with an honestly closed deal.
    function autoAwardXP(address agreement) external {
        if (msg.sender != agreement) revert NotAgreement();
        if (RegistryStorage.store().agreements[agreement].agreement != agreement)
            revert AgreementNotRegistered();

        IAgreementView agmt = IAgreementView(agreement);
        address cli = agmt.client();
        address exc = agmt.executor();
        uint256 amt = agmt.amount();
        uint8   st  = agmt.status();

        ReputationStorage.Data storage d = ReputationStorage.data();

        if (d.clientClaimed[agreement] && d.executorClaimed[agreement]) return;

        // ⚠️ SNAPSHOTTED HERE, AND THE LINE ABOVE `_evalPairCap` IS THE WHOLE
        // POINT. `_evalPairCap` is what counts this deal as a win, for both
        // sides, so a live re-read of `d.countedWins[cli]` after it would
        // include THIS deal and the rule would become "the counterparty has
        // closed two deals, one of which is this one". That is the same defect
        // the old XP snapshot was placed here to avoid — `_addXP` runs twice in
        // this transaction, client then executor — and it survived the gate
        // changing from points to deals because the ordering, not the quantity,
        // is what makes it a PRIOR-standing test.
        //
        // The VALUE, not the verdict: the streak branch reports the count it
        // measured, and a reader asking "how short was I" needs the number.
        uint256 counterpartyWins = d.countedWins[cli];

        _evalPairCap(d, agreement, cli, exc, amt);
        _evalStreakOnce(d, agreement, st, cli, exc, counterpartyWins, agmt);
        _countSettledVolumeOnce(agreement, st, amt);

        if (st == STATUS_RESOLVED) {
            bool clientWon = agmt.clientWonDispute();
            (address winner, address loser) = clientWon ? (cli, exc) : (exc, cli);
            if (!d.clientClaimed[agreement]) d.clientClaimed[agreement] = true;
            if (!d.executorClaimed[agreement]) d.executorClaimed[agreement] = true;
            _addXP(d, agreement, winner, amt);
            _penalizeXP(d, agreement, loser);
        } else {
            if (!d.clientClaimed[agreement]) {
                d.clientClaimed[agreement] = true;
                _addXP(d, agreement, cli, amt);
            }
            if (!d.executorClaimed[agreement]) {
                d.executorClaimed[agreement] = true;
                _addXP(d, agreement, exc, amt);
            }
        }
    }

    /// ERC-2771. Until this existed the facet had no notion of a forwarder at all,
    /// and `claimXP` — the one function in here a person calls with their own
    /// wallet — read `msg.sender`. Relayed, that is the forwarder's address, so
    /// the `NotParty` check below would have refused every gasless claim: the same
    /// shape as incident C1 (`fundDispute`, fix `d172064`), which no direct-call
    /// test could see.
    ///
    /// ⚠️ The two callbacks in this file — `autoAwardXP` and `notifyExecutorFault`
    /// — deliberately keep RAW `msg.sender`. They are contract-to-contract calls
    /// whose whole guard is "are you the Agreement I am about to read?". That
    /// question is about the caller, not about a person behind a messenger, and
    /// `_msgSender()` there would let anyone who can reach the forwarder append
    /// an Agreement's address to the calldata and award themselves XP for a deal
    /// they are not party to.
    function _msgSender() internal view returns (address sender) {
        address forwarder = FactoryStorage.store().trustedForwarder;
        if (msg.sender == forwarder && msg.data.length >= 20) {
            assembly { sender := shr(96, calldataload(sub(calldatasize(), 20))) }
        } else {
            sender = msg.sender;
        }
    }

    /// @notice Manual XP claim for old deals (predating autoAwardXP). Fallback for legacy deals.
    /// Each side calls separately. The pair cap is assessed on the first call.
    function claimXP(address agreement) external {
        ReputationStorage.Data storage d = ReputationStorage.data();

        if (RegistryStorage.store().agreements[agreement].agreement != agreement)
            revert AgreementNotRegistered();

        IAgreementView agmt = IAgreementView(agreement);
        uint8   st  = agmt.status();
        uint256 amt = agmt.amount();
        address cli = agmt.client();
        address exc = agmt.executor();

        if (st != STATUS_COMPLETED && st != STATUS_RESOLVED) revert DealNotEligible();

        address caller = _msgSender();
        if (caller != cli && caller != exc) revert NotParty();

        bool isClient = (caller == cli);
        if (isClient) {
            if (d.clientClaimed[agreement]) revert AlreadyClaimed();
            d.clientClaimed[agreement] = true;
        } else {
            if (d.executorClaimed[agreement]) revert AlreadyClaimed();
            d.executorClaimed[agreement] = true;
        }

        // Before `_evalPairCap`, for the reason written out at the other door:
        // that call counts this very deal as a win for both sides, so a read
        // taken after it would let a deal qualify its own counterparty. One
        // source for this number, two doors reading it the same way.
        uint256 counterpartyWins = d.countedWins[cli];

        _evalPairCap(d, agreement, cli, exc, amt);
        _evalStreakOnce(d, agreement, st, cli, exc, counterpartyWins, agmt);
        // ⚠️ NO `_countSettledVolumeOnce` HERE, AND THE ABSENCE IS THE FIX
        // (12 October 2026). It was called from this door until a measurement
        // showed what that let through: `status()` reads COMPLETED on a deal
        // that is NOT finalized, purely because the auto-approve window ran
        // out. This door accepts that status, so a client could claim here,
        // book the whole escrow as cleanly settled volume, trip the latch --
        // and then the two parties could part through `confirmCancellation`
        // and end the deal REFUNDED with the executor paid nothing. $500 of
        // "clean volume" bought a ceiling for a deal that paid nobody.
        //
        // The difference between the two doors is WHO IS SPEAKING. There
        // `_complete` has already set `_finalized = true` and the clone is
        // telling the diamond "I am over"; here a PERSON is telling it "I think
        // it is over", and his evidence is a `status()` that can still change.
        // Only the first is proof, so only the first counts volume. XP is still
        // awarded here, which is right -- XP was always a per-side claim and
        // its own latches are per side.
        //
        // See `_countSettledVolumeOnce` for what the counter does and does not
        // see now that it has one caller.

        if (st == STATUS_RESOLVED && agmt.clientWonDispute() != isClient) {
            _penalizeXP(d, agreement, caller);
        } else {
            _addXP(d, agreement, caller, amt);
        }
    }

    /// @notice Called by the Agreement on an activation/deadline timeout (the executor's
    /// fault) — resets their clean streak. Never called on an arbiter timeout (not their fault).
    function notifyExecutorFault(address agreement) external {
        if (msg.sender != agreement) revert NotAgreement();
        if (RegistryStorage.store().agreements[agreement].agreement != agreement)
            revert AgreementNotRegistered();

        // ⚠️ THE BOARD RULE REACHES THIS DOOR TOO, AND THIS IS THE DOOR WHERE
        // IT WAS WORTH MONEY (16 October 2026). The streak and its clock are
        // the only way into the arbiter corps, and this function zeroes both
        // of them on a callback the executor cannot refuse.
        //
        // ⚠️ WHAT IT COST BEFORE THIS LINE, AS A NUMBER, because every lever
        // in this protocol is priced. `FactoryFacet.deployAndFund` lets ANY
        // wallet name ANY other wallet as the executor of a deal — the named
        // man presses nothing, by design, that road being an offer rather than
        // an assignment. Fund it, wait out `Agreement.ACTIVATION_WINDOW` (two
        // days), call the activation timeout: the escrow comes back to the
        // caller in full, the only money that does not is the protocol fee —
        // ONE FEE FLOOR — and `_refundBeforeStart(asTimeout: true)` calls this
        // function, which wiped the victim's run and the sixteen days of
        // calendar under it. One dollar and two days to send any candidate for
        // the corps back to the beginning, repeatable with a fresh wallet each
        // time. It is closed here rather than at the clone, because the clone
        // cannot be fixed once it exists (EIP-1167) and this facet can.
        //
        // ⚠️ A BOARD-BORN DEAL STILL BREAKS THE RUN, which is the half that
        // must not be lost: `acceptApplicant` needs the executor's own
        // application and `acceptRequest` is his own press, so a timeout on
        // one of those is a fault on work he asked for. The mark is what tells
        // the two apart, and it was written at the deal's birth.
        if (!DealOriginStorage.data().bornOnBoard[agreement]) return;

        address exc = IAgreementView(agreement).executor();
        ReputationStorage.Data storage d = ReputationStorage.data();
        d.cleanStreak[exc] = 0;
        // The clock is cleared with the run — one of the three reset sites named
        // in `streakClockStartedAt`'s docstring. A streak zeroed here keeps its
        // old start date otherwise, and the sixteen days the arbiter door asks
        // for would already be behind the next run before it began.
        d.streakClockStartedAt[exc] = 0;
    }

    // -------- VIEWS --------

    function getXP(address addr) external view returns (uint256) {
        return ReputationStorage.data().xp[addr];
    }

    function getUniqueActiveUsers() external view returns (uint256) {
        return ReputationStorage.data().uniqueActiveUsers;
    }

    /// @notice Check whether claimant has claimed XP for a particular deal
    function hasClaimed(address agreement, address claimant) external view returns (bool) {
        ReputationStorage.Data storage d = ReputationStorage.data();
        try IAgreementView(agreement).client() returns (address cli) {
            return claimant == cli
                ? d.clientClaimed[agreement]
                : d.executorClaimed[agreement];
        } catch {
            return false;
        }
    }

    function isDealWin(address agreement) external view returns (bool) {
        return ReputationStorage.data().dealIsWin[agreement];
    }

    function getCleanStreak(address addr) external view returns (uint256) {
        return ReputationStorage.data().cleanStreak[addr];
    }

    /// @notice The clean streak, what it cost, and the rule that governs it — in
    /// ONE read, so a screen can be honest about the arbiter door without
    /// keeping a copy of any number in this file.
    ///
    /// @return streak            consecutive clean closes standing right now
    /// @return stalled           completed deals that counted for NOTHING because
    ///                           the counterparty had not yet closed deals of
    ///                           its own. Nonzero here is the whole explanation
    ///                           of "I closed deals and my streak did not move".
    /// @return minCounterpartyWins the number of counted deals a counterparty
    ///                           must already have closed for a deal to count
    ///                           (MIN_COUNTERPARTY_WINS)
    ///
    /// ⚠️ THE THIRD RETURN CHANGED MEANING ON 16 OCTOBER 2026, from an XP bar
    /// to a count of deals, because the gate did. A read that keeps handing out
    /// the old number would be a screen telling a candidate the requirement is
    /// something the chain no longer applies — the same defect as a copy that
    /// drifted, arrived at honestly. The tuple's shape is unchanged, so the
    /// thing that catches a front end still labelling it "XP" is the source
    /// scan in frontend/src/lib/arbiterCaseWork.test.ts, which is red until
    /// that side is corrected.
    ///
    /// ⚠️ THIS EXISTS TO KILL A MIRROR, not only to save a round-trip. The
    /// alternative is a screen with the bar typed into it, which is how the last
    /// four copies of the streak requirement came to disagree with the chain.
    /// The registry's entrance requirement is a different number and comes from
    /// a different door (ArbiterApplicationsFacet.getApplicationRequirements);
    /// this read answers the question BEFORE that one — "is my work even
    /// counting".
    ///
    /// ⚠️ `stalled` counts deals, not the rule's history. It starts at zero for
    /// every address and only ever grows from deals settled after 20 September
    /// 2026 — deals closed before that field existed were stalled in silence
    /// and cannot be recovered, because nothing recorded them. A person whose
    /// streak is short and whose `stalled` is zero may simply be an early user,
    /// and a screen must not read zero as "every deal of yours counted".
    function getStreakStanding(address who)
        external
        view
        returns (uint256 streak, uint256 stalled, uint256 minCounterpartyWins)
    {
        ReputationStorage.Data storage d = ReputationStorage.data();
        return (d.cleanStreak[who], d.streakStalls[who], MIN_COUNTERPARTY_WINS);
    }

    // ⚠️ A READ FOR THIS RULE IS MISSING ON PURPOSE, AND THE GAP IS PRICED.
    //
    // `isBornOnBoard(address)` was written here on 16 October 2026 and taken
    // back out the same day, with a measurement rather than an opinion: ONE new
    // selector anywhere in this tree cost 134 red tests across 11 stands
    // (the five signed-cut rehearsals, their script stands, and the census).
    // The reason is structural and has nothing to do with this facet — every
    // rehearsal builds its rig from `script/DeployFull.s.sol` and asserts the
    // diamond-wide routed count against the chain's signed literal, so any
    // selector the tree gains parts the rig from the chain in ten places at
    // once. The owner's instruction for this piece of work set the limit at one
    // view, and 134 red is past it, so the read waits for his word.
    //
    // ⚠️ WHAT THAT LEAVES BROKEN, SAID PLAINLY: a direct hire now closes
    // perfectly, pays its experience in full, and leaves the run exactly where
    // it was — and on every screen we have that is INDISTINGUISHABLE from a
    // board deal that counted. `_evalStreakOnce` returns before its log for
    // these deals, so there is no event either. The streak is the only door
    // into the arbiter corps, so a man working off-board watches it stand still
    // with nothing anywhere telling him why.
    //
    // ⚠️ AND IT IS NOT DERIVABLE OFF-CHAIN TODAY, which was checked rather
    // than assumed: the boards store job -> agreement and there is no reverse
    // read, so a deal screen holding only the clone's address cannot ask which
    // job made it without walking the whole board — the per-request cost this
    // project already has a rule against.

    /// @notice How many of this address's disputes ended with no verdict (a timeout —
    /// a 50/50 split, or 75/25 when one side never answered). Counted for both
    /// participants of the deal; neither a verdict nor an accusation, see the
    /// comment on the unresolvedDisputes field.
    function getUnresolvedDisputes(address who) external view returns (uint256) {
        return ReputationStorage.data().unresolvedDisputes[who];
    }

    // -------- INTERNAL --------

    function _evalPairCap(
        ReputationStorage.Data storage d,
        address agreement,
        address cli,
        address exc,
        uint256 amt
    ) private {
        if (d.pairCounted[agreement]) return;
        d.pairCounted[agreement] = true;
        if (amt >= MIN_WIN_AMOUNT) {
            bytes32 pk = _pairKey(cli, exc);
            if (d.pairWins[pk] < MAX_WINS_PAIR) {
                d.pairWins[pk]++;
                d.dealIsWin[agreement] = true;
                // ⚠️ THE ONLY PLACE A COUNTED WIN IS COUNTED PER ADDRESS, and
                // it is inside the branch that decides `dealIsWin` rather than
                // beside it. The counterparty bar in `_evalStreakOnce` reads
                // this number, so a second test of "is this a win" written
                // anywhere else would be a second definition, and two
                // definitions of the same word disagree about a particular deal
                // in silence — with nothing in the protocol able to say which
                // one was right. Both sides, because `dealIsWin` is a fact
                // about the deal: see `countedWins` in the struct for why a
                // lost dispute counting here makes the bar no cheaper.
                //
                // ⚠️ THE GATE IS AROUND THESE TWO LINES AND NOTHING ELSE
                // (16 October 2026, the owner's decision). `dealIsWin`,
                // `pairWins` and therefore every XP number above and below are
                // left exactly where they were: a direct hire still pays its
                // experience in full, still counts against the three-per-pair
                // cap, and still costs the loser of a dispute half a win. What
                // it no longer does is build the standing that moves somebody
                // ELSE'S clean streak, because the streak measures what the
                // board brought in. Gating `dealIsWin` instead would have been
                // the same change written one layer too low, and it would have
                // silently rewritten the XP rules on the way past.
                if (DealOriginStorage.data().bornOnBoard[agreement]) {
                    d.countedWins[cli]++;
                    d.countedWins[exc]++;
                }
            }
        }
    }

    /// @notice Updates the executor's clean streak exactly once per deal, no matter how
    /// many times autoAwardXP/claimXP are called for it (claimXP is called separately by
    /// each side), AND SAYS OUT LOUD WHAT IT DID.
    ///
    /// The rules:
    ///   BORN ON A BOARD, before anything else — a deal the board did not make
    ///     moves nothing in either direction and records nothing. See the gate
    ///     itself for why both directions, and `DealOriginStorage` for why the
    ///     answer has to have been written at the deal's birth.
    ///   COMPLETED — the deal could not have gone to dispute at all, so it is clean: +1,
    ///     but only if the counterparty of this deal had already closed
    ///     countedWins >= MIN_COUNTERPARTY_WINS deals BEFORE it. Otherwise a ring of
    ///     fresh wallets would run a streak up on each other for free. The count is
    ///     snapshotted once before `_evalPairCap` in this transaction, because that
    ///     call counts THIS deal as a win for both sides and a later read would let
    ///     the deal qualify its own counterparty.
    ///   RESOLVED — there was a dispute; the executor lost: reset; won: unchanged.
    ///
    /// ⚠️ THE COUNTERPARTY TEST WAS `xp >= 50` UNTIL 16 OCTOBER 2026. It is a
    /// count of closed deals now, for the reason written at
    /// MIN_COUNTERPARTY_WINS: points are paid per win AND per unit of volume,
    /// so a points bar was satisfiable by one large escrow and never measured
    /// how many deals had happened at all.
    ///
    /// ⚠️ WHAT IS NEW IS THAT THE RULE STOPPED BEING SILENT, and that is not a
    /// decoration. Before this, a deal that closed perfectly and counted for
    /// nothing looked EXACTLY like a deal that counted: same events, same
    /// screens, same everything. A person could work a year with newcomers,
    /// believe a streak was accumulating, and hold zero. That was survivable
    /// while the corps also had an XP door; it is a plain broken promise now
    /// that the streak is the only way in.
    ///
    /// So every outcome, including "nothing happened", leaves a named reason in
    /// the log, and the one outcome a person cannot otherwise account for — a
    /// clean close that moved nothing — also increments a counter a screen can
    /// read without an indexer.
    ///
    /// ⚠️ A deal that ends REFUNDED reaches neither branch and emits nothing,
    /// on purpose: nothing was delivered and nothing was judged, so there is no
    /// verdict about the executor's run to report.
    function _evalStreakOnce(
        ReputationStorage.Data storage d,
        address agreement,
        uint8 st,
        address cli,
        address exc,
        uint256 counterpartyWins,
        IAgreementView agmt
    ) private {
        // ⚠️ THE FIRST QUESTION IS WHERE THE DEAL CAME FROM, AND A DEAL THE
        // BOARD DID NOT MAKE LEAVES THIS FUNCTION WITHOUT TOUCHING ANYTHING
        // (16 October 2026, the owner's decision: "if the two of you agreed
        // directly, the gate does not touch it; if you found the client
        // through the board, then it works").
        //
        // ⚠️ IT GUARDS BOTH DIRECTIONS, NOT ONLY THE TICK, and that is the
        // literal reading of "does not touch it" rather than a liberty taken
        // here. A direct hire neither advances the run nor breaks it. The
        // asymmetric version — off-board deals cannot lengthen a streak but
        // can still end one — reads cautious and is the dangerous one: it
        // hands anybody a lever over a candidate's record that the candidate
        // never agreed to be measured by, and the only thing it protects is a
        // number the owner has just said does not describe that half of his
        // work.
        //
        // ⚠️ BEFORE THE `streakEvaluated` LATCH ON PURPOSE. The latch exists to
        // make the verdict once-per-deal; an off-board deal has no verdict to
        // record, so there is nothing to latch and no SSTORE to pay for. The
        // mark itself can never change — it is written at birth and nothing
        // writes it again — so a second pass through here reaches the same
        // answer from the same slot.
        //
        // ⚠️ AND NOTHING IS EMITTED, for the reason the REFUNDED note below
        // gives for its own silence: `CleanStreakEvaluated` reports what this
        // rule DID to a run, and this rule was not applied. Reporting it as
        // `CounterpartyTooNew` would be worse than silence — it would tell a
        // man his oldest client is new.
        //
        // ⚠️ SO FOR NOW THESE DEALS MOVE NOTHING AND SAY NOTHING, which is a
        // known, measured gap and not an oversight: see the note where the
        // read that would close it used to stand, in the VIEWS section above.
        if (!DealOriginStorage.data().bornOnBoard[agreement]) return;

        if (d.streakEvaluated[agreement]) return;
        d.streakEvaluated[agreement] = true;

        if (st == STATUS_COMPLETED) {
            if (counterpartyWins >= MIN_COUNTERPARTY_WINS) {
                // ⚠️ ONE TICK PER CLIENT, EVER (12 October 2026). The streak
                // counts DISTINCT clients, not deals — see
                // `streakClientCounted` in the struct for the six-dollar run
                // this closes. The deal is not punished in any other way: the
                // XP for both sides is awarded below exactly as before, because
                // a protocol in which a repeat client is worth less than a
                // stranger has made a permanent client unreachable, and the
                // owner ruled that out in the same breath as this rule.
                if (d.streakClientCounted[exc][cli]) {
                    emit CleanStreakEvaluated(
                        exc,
                        agreement,
                        StreakOutcome.CounterpartyAlreadyCounted,
                        d.cleanStreak[exc],
                        counterpartyWins
                    );
                    return;
                }
                d.streakClientCounted[exc][cli] = true;

                uint256 grown = d.cleanStreak[exc] + 1;
                d.cleanStreak[exc] = grown;

                // The clock under this run starts at its FIRST tick and is not
                // restarted by later ones. Written on the tick that finds the
                // field at zero rather than on `grown == 1`, deliberately: a
                // streak that was already standing when this field was appended
                // has no recorded start, and this way its next tick gives it
                // one instead of leaving it permanently unmeasurable.
                if (d.streakClockStartedAt[exc] == 0) {
                    d.streakClockStartedAt[exc] = block.timestamp;
                }

                emit CleanStreakEvaluated(
                    exc, agreement, StreakOutcome.Advanced, grown, counterpartyWins
                );
            } else {
                // The deal closed clean and bought nothing: the other side had
                // not closed MIN_COUNTERPARTY_WINS deals of its own yet. This
                // is the case the counter exists for — see streakStalls.
                //
                // ⚠️ THE NAME `CounterpartyTooNew` IS KEPT AND THE ENUM IS NOT
                // TOUCHED. The log carries the member's NUMBER, so renaming is
                // free and reordering would re-label history; and "too new" is
                // still exactly what the refusal means — it is measured in
                // deals closed now rather than in points earned.
                d.streakStalls[exc]++;
                emit CleanStreakEvaluated(
                    exc,
                    agreement,
                    StreakOutcome.CounterpartyTooNew,
                    d.cleanStreak[exc],
                    counterpartyWins
                );
            }
        } else if (st == STATUS_RESOLVED) {
            if (agmt.clientWonDispute()) {
                d.cleanStreak[exc] = 0;
                // ⚠️ THE CLOCK GOES WITH IT. A date that outlives the run it
                // measured is the whole fix undone: five fresh ticks a year
                // later would read as a run sixteen days old on the strength of
                // a streak that was broken and is gone. Measured by
                // test/CleanStreakCostsSixDollars.t.sol, in a scene of its own
                // rather than as a line inside another — this is the one reset
                // that is easy to believe is "obviously" handled.
                d.streakClockStartedAt[exc] = 0;
                emit CleanStreakEvaluated(
                    exc, agreement, StreakOutcome.BrokenByLostDispute, 0, counterpartyWins
                );
            } else {
                emit CleanStreakEvaluated(
                    exc,
                    agreement,
                    StreakOutcome.HeldByWonDispute,
                    d.cleanStreak[exc],
                    counterpartyWins
                );
            }
        }
    }

    /// @notice Adds a cleanly closed deal's escrow to the protocol's settled
    ///         volume — the counter the growing deal cap is computed from —
    ///         EXACTLY ONCE per agreement.
    ///
    /// @dev ⚠️ EXACTLY ONE CALLER, AND IT IS `autoAwardXP` (12 October 2026).
    ///      `claimXP` used to call this too and no longer does. The reason is
    ///      written out at the gap it left behind, and in one line: `claimXP`
    ///      runs on a `status()` that reads COMPLETED when the auto-approve
    ///      window has merely expired, so a deal counted from there could still
    ///      end REFUNDED with nobody paid. `autoAwardXP` is called from
    ///      `Agreement._complete`, AFTER `_finalized = true` and only for
    ///      COMPLETED or RESOLVED — the clone saying "I am over" rather than a
    ///      person saying "I think it is over". Only the first is evidence.
    ///
    /// @dev ⚠️ THE LATCH IS STILL THE WHOLE FUNCTION, and one caller does not
    ///      make it decoration. Two reasons one deal still reaches this code
    ///      more than once:
    ///
    ///        * `autoAwardXP` says in its own comments that it may be called
    ///          repeatedly for one agreement; its early return only fires once
    ///          BOTH sides are flagged, and a RESOLVED deal flags both in one
    ///          go while a COMPLETED one can be reached again in between.
    ///        * `_addXP` runs once per RECIPIENT, not once per deal — twice in
    ///          one transaction on the ordinary completion path, client then
    ///          executor. A counter placed inside it would double every deal,
    ///          which is why this one is called from the body above it instead.
    ///
    ///      Doubling the counter is not a cosmetic error: the cap is a fixed
    ///      share of it, so a counter that can be made to count twice halves
    ///      the cost of farming the ceiling, which is the one thing the share
    ///      being tied to the fee rate was chosen to make unprofitable.
    ///
    ///      A latch of its own rather than a ride on `pairCounted` or
    ///      `streakEvaluated`: both of those carry conditions that have nothing
    ///      to do with volume (`pairCounted` is about the 3-wins-per-pair cap,
    ///      and the first claimer sets it even when the deal is below
    ///      MIN_WIN_AMOUNT), and a counter that silently inherits somebody
    ///      else's rule is a counter that changes when that rule is next
    ///      edited. It lives in the cap's own namespace next to the number it
    ///      guards.
    ///
    /// @dev COMPLETED ONLY, and RESOLVED is excluded on purpose — see
    ///      DealCapStorage.settledVolume for why a disputed deal must not buy
    ///      the protocol a bigger ceiling. REFUNDED reaches neither branch:
    ///      nothing was delivered.
    ///
    ///      That exclusion is safe to state as "closed without a dispute"
    ///      rather than merely "status 3", and it was checked rather than
    ///      assumed: both paths in Agreement that end in COMPLETED (`release`
    ///      and the auto-approve) refuse outright once `_disputedAt != 0`, so a
    ///      deal that ever saw a dispute cannot arrive here wearing COMPLETED.
    ///
    ///      The latch is set on the first call whatever the status, and with
    ///      one caller that is now sound rather than merely convenient. The
    ///      claim it used to rest on was FALSE and was measured false: it said
    ///      "both callers only ever run on a finished deal ... so the status
    ///      this sees is the deal's final one and cannot later change". It
    ///      cannot change HERE, because `_complete` has set `_finalized` and
    ///      `_finalStatus` before this call is made and nothing in the clone
    ///      moves either again. It COULD change on the other door, and that is
    ///      precisely why the other door no longer calls this.
    ///
    /// @dev ⚠️ THREE PLACES THIS COUNTER UNDERCOUNTS ON PURPOSE, written down
    ///      so the next reader recognises them as decisions and not as the bug
    ///      they look like. Every one of the three makes the counter SMALLER,
    ///      which makes the ceiling grow SLOWER — the safe direction, since the
    ///      ceiling is a bound and a bound that lags is still a bound:
    ///
    ///        1. IT COUNTS `amount`, NOT THE POT. A deal that was born at $500
    ///           and topped up to $1,500 feeds $500 in. Reading `extrasTotal()`
    ///           here is not an option and that was checked, not guessed: every
    ///           clone created before that field existed has no such function,
    ///           the call would revert inside `autoAwardXP`, and `_complete`'s
    ///           try/catch would swallow it — breaking XP on every deal already
    ///           alive. A clone cannot be fixed (EIP-1167), so the read would
    ///           be permanent for exactly the deals that cannot afford it.
    ///        2. `autoAwardXP` IS CALLED INSIDE A try/catch WITH A GAS CAP. A
    ///           call that runs out of its XP_AWARD_GAS budget loses the XP and
    ///           the volume together, silently, with only `XpAwardFailed` in
    ///           the log.
    ///        3. THE EARLY RETURN `if (clientClaimed && executorClaimed)` IN
    ///           `autoAwardXP` FIRES FIRST. A deal both of whose halves were
    ///           already taken through the legacy `claimXP` door never reaches
    ///           this function at all, and buys no ceiling.
    function _countSettledVolumeOnce(
        address agreement,
        uint8 st,
        uint256 amt
    ) private {
        DealCapStorage.Data storage c = DealCapStorage.data();
        if (c.volumeCounted[agreement]) return;
        c.volumeCounted[agreement] = true;

        if (st != STATUS_COMPLETED) return;

        uint256 total = c.settledVolume + amt;
        c.settledVolume = total;
        emit SettledVolumeCounted(agreement, amt, total);
    }

    function _addXP(
        ReputationStorage.Data storage d,
        address agreement,
        address recipient,
        uint256 amt
    ) private {
        uint256 xpGain = d.dealIsWin[agreement] ? WIN_XP : 0;

        if (amt >= MIN_WIN_AMOUNT) {
            uint256 accrued = d.volumeXPAccrued[recipient];
            if (accrued < MAX_VOLUME_XP) {
                uint256 volGain = _min(amt / 10_000_000, MAX_VOLUME_XP - accrued);
                xpGain += volGain;
                d.volumeXPAccrued[recipient] = accrued + volGain;
            }
        }

        if (xpGain > 0) {
            if (!d.hasEarnedXP[recipient]) {
                d.hasEarnedXP[recipient] = true;
                d.uniqueActiveUsers++;
            }
            d.xp[recipient] += xpGain;
            emit XPClaimed(agreement, recipient, xpGain);
        }
    }

    /// @notice Takes XP away from the losing side of a dispute. The same threshold as for
    /// wins (>=10 USDC, cap of 3 events per pair through dealIsWin) — otherwise someone's
    /// rating could be farmed downwards with a run of tiny lost disputes. Never drives
    /// xp[loser] below zero.
    function _penalizeXP(
        ReputationStorage.Data storage d,
        address agreement,
        address loser
    ) private {
        if (!d.dealIsWin[agreement]) return;

        uint256 current = d.xp[loser];
        uint256 penalty = _min(LOSS_XP_PENALTY, current);
        if (penalty == 0) return;

        d.xp[loser] = current - penalty;
        emit XPPenalized(agreement, loser, penalty);
    }

    function _pairKey(address a, address b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
