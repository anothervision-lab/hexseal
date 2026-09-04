// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ReputationFacet.sol
//
// On-chain XP system. Users claim XP once a deal is finished.
// Anti-gaming: deal >= 10 USDC, cap of 3 wins per pair of addresses.
// uniqueActiveUsers — count of distinct addresses with XP > 0 (the DAO trigger).
//
// Phase 2 (xp >= PHASE2_XP_THRESHOLD): client XP freezes, and executor XP grows
// only while their cleanStreak (consecutive clean closes) is
// >= CLEAN_STREAK_REQUIRED — otherwise capital placed in one large deal would
// buy reputation on a par with years of honest work.
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
    uint256 private constant PHASE2_XP_THRESHOLD   = 1000; // above this the client's XP is frozen and the executor's is gated by the streak
    uint256 private constant CLEAN_STREAK_REQUIRED = 10;   // consecutive clean closes required for executor XP to grow past PHASE2_XP_THRESHOLD
    uint256 private constant MIN_COUNTERPARTY_XP   = 50;    // a deal counts toward cleanStreak/Phase-2 XP only if the counterparty already holds this standing — not from this same deal

    // Agreement.sol 7-state enum
    uint8 private constant STATUS_COMPLETED = 3;
    uint8 private constant STATUS_RESOLVED  = 5;

    // -------- EVENTS --------

    event XPClaimed(address indexed agreement, address indexed claimant, uint256 xpGained);
    event XPPenalized(address indexed agreement, address indexed loser, uint256 xpLost);

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

        // Snapshotted once, before either side's XP is touched below — _awardXP runs
        // twice in this same transaction (client then executor), and a live re-read of
        // d.xp[cli] on the second call would see the client's own just-granted Phase-1
        // XP from THIS deal, defeating the "counterparty had PRIOR standing" requirement.
        bool counterpartyQualified = d.xp[cli] >= MIN_COUNTERPARTY_XP;

        _evalPairCap(d, agreement, cli, exc, amt);
        _evalStreakOnce(d, agreement, st, exc, counterpartyQualified, agmt);

        if (st == STATUS_RESOLVED) {
            bool clientWon = agmt.clientWonDispute();
            (address winner, address loser) = clientWon ? (cli, exc) : (exc, cli);
            if (!d.clientClaimed[agreement]) d.clientClaimed[agreement] = true;
            if (!d.executorClaimed[agreement]) d.executorClaimed[agreement] = true;
            _awardXP(d, agreement, winner, exc, counterpartyQualified, amt);
            _penalizeXP(d, agreement, loser);
        } else {
            if (!d.clientClaimed[agreement]) {
                d.clientClaimed[agreement] = true;
                _awardXP(d, agreement, cli, exc, counterpartyQualified, amt);
            }
            if (!d.executorClaimed[agreement]) {
                d.executorClaimed[agreement] = true;
                _awardXP(d, agreement, exc, exc, counterpartyQualified, amt);
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

        bool counterpartyQualified = d.xp[cli] >= MIN_COUNTERPARTY_XP;

        _evalPairCap(d, agreement, cli, exc, amt);
        _evalStreakOnce(d, agreement, st, exc, counterpartyQualified, agmt);

        if (st == STATUS_RESOLVED && agmt.clientWonDispute() != isClient) {
            _penalizeXP(d, agreement, caller);
        } else {
            _awardXP(d, agreement, caller, exc, counterpartyQualified, amt);
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
    /// each side). COMPLETED — the deal could not have gone to dispute at all, so it is
    /// clean: +1, but only if the counterparty of this deal already held
    /// xp >= MIN_COUNTERPARTY_XP before it — otherwise a sybil ring of fresh wallets could
    /// run up a streak on each other for free. The qualification is snapshotted once before
    /// any awards in this transaction (in autoAwardXP the client is awarded first, raising
    /// d.xp[cli], so a second read by the executor would see an already changed balance).
    /// RESOLVED — there was a dispute; the executor lost: reset; won: unchanged.
    function _evalStreakOnce(
        ReputationStorage.Data storage d,
        address agreement,
        uint8 st,
        address exc,
        bool counterpartyQualified,
        IAgreementView agmt
    ) private {
        if (d.streakEvaluated[agreement]) return;
        d.streakEvaluated[agreement] = true;

        if (st == STATUS_COMPLETED) {
            if (counterpartyQualified) {
                d.cleanStreak[exc]++;
            }
        } else if (st == STATUS_RESOLVED && agmt.clientWonDispute()) {
            d.cleanStreak[exc] = 0;
        }
    }

    /// @notice Awards XP by the ordinary formula (_addXP), but gates awards above
    /// PHASE2_XP_THRESHOLD: a client past the threshold gets no XP at all, an executor gets
    /// it only while their cleanStreak >= CLEAN_STREAK_REQUIRED AND the counterparty of this
    /// particular deal already held xp >= MIN_COUNTERPARTY_XP before it (not as a result of
    /// this same deal) — without that second check one could run up a streak honestly once
    /// and then farm the remaining Phase-2 XP on their own sybil wallets. The counterparty
    /// qualification is snapshotted once before any awards in this transaction (in
    /// autoAwardXP the client is awarded first).
    function _awardXP(
        ReputationStorage.Data storage d,
        address agreement,
        address recipient,
        address exc,
        bool counterpartyQualified,
        uint256 amt
    ) private {
        if (d.xp[recipient] >= PHASE2_XP_THRESHOLD) {
            if (recipient != exc) return;
            if (d.cleanStreak[recipient] < CLEAN_STREAK_REQUIRED) return;
            if (!counterpartyQualified) return;
        }
        _addXP(d, agreement, recipient, amt);
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
