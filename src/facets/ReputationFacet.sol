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
// What still holds the number honest, and is deliberately KEPT: the 10 USDC
// floor under a deal, the cap of 3 counted wins per pair, the 300-point ceiling
// on volume XP, and MIN_COUNTERPARTY_XP — the requirement that the OTHER side
// of a deal already carried standing of its own before that deal can move a
// clean streak. Those bound what one address can manufacture; Phase 2 only
// bound how fast an honest one could grow.
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
        // advance the clean streak because the counterparty held less than
        // MIN_COUNTERPARTY_XP before them. The rule itself is old; until this
        // field it was enforced in COMPLETE SILENCE — no event, no read, no
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
    /// A deal moves the executor's clean streak only if the OTHER side already
    /// held this much standing BEFORE it — not standing gained from this very
    /// deal. It is what stops a ring of fresh wallets running a streak up on
    /// each other for nothing, and with the streak now being the only door into
    /// the arbiter corps it is the load-bearing number of this file.
    ///
    /// ⚠️ It is also the number that used to be invisible. See streakStalls in
    /// the struct above and CleanStreakEvaluated below: every deal that fails
    /// this test now says so out loud and carries the counterparty's actual
    /// standing with it, so "why did my streak not move" has an answer that
    /// does not require reading this source.
    ///
    /// ⚠️ NOT MIRRORED ANYWHERE. `getStreakStanding` hands it out with the two
    /// numbers it explains, so a screen reads it and does not keep a copy.
    uint256 private constant MIN_COUNTERPARTY_XP   = 50;

    // PHASE2_XP_THRESHOLD (1000) and CLEAN_STREAK_REQUIRED (10) were deleted on
    // 20 September 2026 together with the gate they fed — see the file header.
    // They are not "kept as an anchor for the future": an unread constant is a
    // number that drifts in silence, and this file has said so before about a
    // neighbour's mirror.

    // Agreement.sol 7-state enum
    uint8 private constant STATUS_COMPLETED = 3;
    uint8 private constant STATUS_RESOLVED  = 5;

    // -------- EVENTS --------

    event XPClaimed(address indexed agreement, address indexed claimant, uint256 xpGained);
    event XPPenalized(address indexed agreement, address indexed loser, uint256 xpLost);

    /// What a finished deal did to the executor's clean streak, and WHY.
    ///
    /// Emitted exactly once per deal, from the same one-shot branch that moves
    /// the streak (`_evalStreakOnce`), so the log and the stored number can
    /// never disagree about a deal. `streak` is the value AFTER the deal —
    /// unchanged is a perfectly ordinary answer and is reported as such.
    /// `counterpartyXP` is the standing the other side held BEFORE this deal,
    /// which is the whole of the reason in the CounterpartyTooNew case; it is
    /// carried in the log rather than looked up afterwards because by the time
    /// anybody reads this, that balance has moved on.
    event CleanStreakEvaluated(
        address indexed executor,
        address indexed agreement,
        StreakOutcome   outcome,
        uint256         streak,
        uint256         counterpartyXP
    );

    // -------- TYPES --------

    /// The four things that can happen to a clean streak when a deal ends.
    /// Named rather than numbered: a reader of the feed should not have to know
    /// that 1 means "your client was too new".
    enum StreakOutcome {
        Advanced,            // closed clean, counterparty had standing — +1
        CounterpartyTooNew,  // closed clean and counted for NOTHING: the counterparty held < MIN_COUNTERPARTY_XP
        BrokenByLostDispute, // a dispute the executor lost — back to zero
        HeldByWonDispute     // a dispute the executor won — neither advanced nor broken
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

        // Snapshotted once, before either side's XP is touched below — _addXP runs
        // twice in this same transaction (client then executor), and a live re-read of
        // d.xp[cli] afterwards would see the client's own just-granted XP from THIS
        // deal, defeating the "counterparty had PRIOR standing" requirement.
        //
        // The VALUE, not the verdict: the streak branch reports the standing it
        // measured, and a reader asking "how short was I" needs the number.
        uint256 counterpartyXP = d.xp[cli];

        _evalPairCap(d, agreement, cli, exc, amt);
        _evalStreakOnce(d, agreement, st, exc, counterpartyXP, agmt);

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

        uint256 counterpartyXP = d.xp[cli];

        _evalPairCap(d, agreement, cli, exc, amt);
        _evalStreakOnce(d, agreement, st, exc, counterpartyXP, agmt);

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

        address exc = IAgreementView(agreement).executor();
        ReputationStorage.data().cleanStreak[exc] = 0;
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
    ///                           the counterparty had not yet earned standing of
    ///                           its own. Nonzero here is the whole explanation
    ///                           of "I closed deals and my streak did not move".
    /// @return minCounterpartyXP the standing a counterparty must already hold
    ///                           for a deal to count (MIN_COUNTERPARTY_XP)
    ///
    /// ⚠️ THIS EXISTS TO KILL A MIRROR, not only to save a round-trip. The
    /// alternative is a screen with `50` typed into it, which is how the last
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
        returns (uint256 streak, uint256 stalled, uint256 minCounterpartyXP)
    {
        ReputationStorage.Data storage d = ReputationStorage.data();
        return (d.cleanStreak[who], d.streakStalls[who], MIN_COUNTERPARTY_XP);
    }

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
            }
        }
    }

    /// @notice Updates the executor's clean streak exactly once per deal, no matter how
    /// many times autoAwardXP/claimXP are called for it (claimXP is called separately by
    /// each side), AND SAYS OUT LOUD WHAT IT DID.
    ///
    /// The rules themselves are unchanged (20 September 2026):
    ///   COMPLETED — the deal could not have gone to dispute at all, so it is clean: +1,
    ///     but only if the counterparty of this deal already held
    ///     xp >= MIN_COUNTERPARTY_XP BEFORE it. Otherwise a ring of fresh wallets would
    ///     run a streak up on each other for free. The standing is snapshotted once
    ///     before any award in this transaction (in autoAwardXP the client is awarded
    ///     first, raising d.xp[cli], so a later read would see an already changed balance).
    ///   RESOLVED — there was a dispute; the executor lost: reset; won: unchanged.
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
        address exc,
        uint256 counterpartyXP,
        IAgreementView agmt
    ) private {
        if (d.streakEvaluated[agreement]) return;
        d.streakEvaluated[agreement] = true;

        if (st == STATUS_COMPLETED) {
            if (counterpartyXP >= MIN_COUNTERPARTY_XP) {
                uint256 grown = d.cleanStreak[exc] + 1;
                d.cleanStreak[exc] = grown;
                emit CleanStreakEvaluated(
                    exc, agreement, StreakOutcome.Advanced, grown, counterpartyXP
                );
            } else {
                // The deal closed clean and bought nothing. This is the case the
                // counter exists for — see streakStalls.
                d.streakStalls[exc]++;
                emit CleanStreakEvaluated(
                    exc,
                    agreement,
                    StreakOutcome.CounterpartyTooNew,
                    d.cleanStreak[exc],
                    counterpartyXP
                );
            }
        } else if (st == STATUS_RESOLVED) {
            if (agmt.clientWonDispute()) {
                d.cleanStreak[exc] = 0;
                emit CleanStreakEvaluated(
                    exc, agreement, StreakOutcome.BrokenByLostDispute, 0, counterpartyXP
                );
            } else {
                emit CleanStreakEvaluated(
                    exc,
                    agreement,
                    StreakOutcome.HeldByWonDispute,
                    d.cleanStreak[exc],
                    counterpartyXP
                );
            }
        }
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
