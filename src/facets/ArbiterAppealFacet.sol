// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ArbiterAppealFacet.sol
//
// THE APPEAL, carved out of ArbiterRegistryFacet on 15 October 2026.
//
// ── WHY THIS FILE EXISTS, AS ONE NUMBER ───────────────────────────────────
// Measured on a clean tree at 299d8b62 with solc 0.8.31, via-ir, optimizer
// 200, reading `deployedBytecode` out of out/<Facet>.sol/<Facet>.json:
//
//     ArbiterRegistryFacet        23 107 bytes    1 469 to spare
//     ArbiterAccountabilityFacet  10 222 bytes   14 354 to spare
//     ArbiterVaultFacet           10 737 bytes   13 839 to spare
//     ArbiterApplicationsFacet     4 264 bytes   20 312 to spare
//
// 1 469 bytes against the EIP-170 limit of 24 576 is less than one ordinary
// external function of this repository costs, and the next piece of work in
// the queue is a price that GROWS on three doors — a price per vote cast, a
// price on the man who raises an appeal, and a price on the man who opens a
// dispute, each with a counter and a cooling-off clock. Two of those three
// doors are in this file. Without the split there is nowhere to put them.
//
// ⚠️ THE SPLIT BUYS ROOM IN THE CHAIN AND NOTHING ELSE. It does NOT make the
// build cheaper or lighter: the compilation unit here is the whole tree, which
// was measured the same day. Anyone reading this as a build-time improvement
// will be disappointed by a measurement.
//
// ── THIS EXACT SPLIT WAS CONSIDERED AND REFUSED IN SEPTEMBER 2026 ─────────
// The header of ArbiterVaultFacet still carries the reason, and it should be
// read before this file is judged: the appeal group was the FIRST candidate
// and was rejected because `resolveAppeal` called four helpers the registry
// keeps for other callers — `_recordArbiterMistake`, `_slashArbiterXP`,
// `_hasLiveProposalHere` and `_softTransfer` — so moving the appeal would mean
// "a second copy of the rules that suspend an arbiter and record an
// accusation, in a second file, with nothing that goes red when the two
// drift".
//
// TWO OF THOSE FOUR STOPPED BEING SHARED, and not because anybody wanted this
// split: the owner's hand left the protocol on 9 October 2026 together with
// `overturnVerdict`, which was the other caller of both. Measured on this tree
// by counting call sites, not assumed:
//
//     _slashArbiterXP        1 caller  (resolveAppeal)            → MOVED HERE
//     _hasLiveProposalHere   2 callers, neither in the appeal     → stays
//     _recordArbiterMistake  3 callers (2 of them in the registry)→ shared
//     _softTransfer          3 callers (2 of them in the registry)→ shared
//     _requireNotSuspended   4 callers (3 of them in the registry)→ shared
//
// ── AND THE SHARED ONES ARE NOT COPIED, THEY MOVED INTO THE LIBRARY ───────
// September's objection is answered mechanically rather than promised away.
// `requireNotSuspended`, `softTransfer`, `recordArbiterMistake`,
// `suspendAndAccuse`, `causeForPath`, `hasLiveProposalHere` and the constants
// `FINALIZE_DELAY` and `MAX_ARBITER_MISTAKES` now live in
// `ArbiterRegistryStorage`, the library declared in ArbiterRegistryFacet.sol —
// ONE declaration, called by both facets, impossible to drift without
// somebody editing that one body. That is the same device the library already
// used for `clearSeat`, `recordClosedCase`, `recordRemovalForCause` and
// `clearRemovalRecord`: the shared consequences of the arbiter's life live
// beside the storage they write, not in whichever facet happened to need them
// first.
//
// ⚠️ A LIBRARY'S `internal` CODE IS INLINED INTO EVERY CALLER, so both facets
// carry their own machine code for those bodies and the registry gives up
// nothing by sharing them. What is shared is the SOURCE, which is the only
// thing that can drift.
//
// ── STORAGE IS THE SAME MEMORY, NOT A COPY ────────────────────────────────
// This facet declares NO storage of its own and no `struct` of its own. Every
// read and write goes through `ArbiterRegistryStorage.data()`, which resolves
// to the fixed ERC-7201 slot
// 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00. A facet
// runs by DELEGATECALL, so the storage it touches is the PROXY's: `raiseAppeal`
// here and `finalizeVerdict` in the registry see one `pendingVerdicts`, and
// nothing about this move needs a migration. Not one field of `Data` was
// touched by this split — a retype inside a live slot is the July 2026 bug
// this repository keeps three gates for.
//
// ── EVENTS AND ERRORS ARE THE REGISTRY'S, BY NAME ─────────────────────────
// Nothing below declares an event or an error of its own; they are emitted and
// reverted as `ArbiterRegistryFacet.X(...)` — one declaration, the same topic0,
// the same four bytes, no drift possible. A log carries the DIAMOND's address
// as its emitter either way, so the subgraph and the browser see no difference.
//
// ── ERC-2771 ──────────────────────────────────────────────────────────────
// `_msgSender()` below is the copy every facet of this repository declares for
// itself (eight lines; facets do not inherit from one another). It is the only
// sender read for anything a person does here: `raiseAppeal`,
// `voteToOverturn`, and — from 29 October 2026 — ONE BRANCH of
// `summonAppealPanel`. `resolveAppeal` reads NO sender at all, on purpose, and
// so does the ordinary pull of the lot: who sends those cannot change their
// answer, so there is nothing for a forwarder to get wrong on them.
//
// ⚠️ THE SENTENCE HERE SAID `summonAppealPanel` READ NO SENDER AT ALL UNTIL
// 29 OCTOBER 2026, and the half that is still true is the half that matters:
// the FIRST pull is permissionless and senderless, so a closed browser or a
// relayer that was down costs nobody his appeal. What reads a sender is the
// branch where the seed has gone stale and the lot is thrown AGAIN, because
// decision 244 gives that choice to the appellant alone. The class of bug this
// guards against is `fundDispute` reading `msg.sender` and seeing the
// forwarder (fixed in d172064, 31 July 2026) — and that branch is exactly its
// shape, so a test that calls the facet directly cannot prove it: the lock for
// it goes through a real forwarder.
// ============================================================

import "../../src/FactoryFacet.sol";          // FactoryStorage (trustedForwarder, usdc)
import "../../src/facets/ReputationFacet.sol"; // ReputationStorage (XP)
import "../RegistryFacet.sol";                 // RegistryStorage — the deal's recorded parties
import {ArbiterRegistryStorage, ArbiterRegistryFacet, IUSDCFull} from "./ArbiterRegistryFacet.sol";

contract ArbiterAppealFacet {

    // -------- CONSTANTS --------
    //
    // Every constant below moved here WHOLE: after the split the registry has
    // no reader of any of them left (measured by grepping call sites on this
    // tree, not assumed), so these are moves and not mirrors. The three the
    // appeal shares with what stayed behind — FINALIZE_DELAY,
    // MAX_ARBITER_MISTAKES and the two PROPOSAL/REMOVAL mirrors — are NOT
    // declared here at all: they are read from `ArbiterRegistryStorage`, for
    // the reason the header gives. An unread copy is a mirror, and this
    // repository has already paid for one (see the note where the DEAD copy of
    // ARBITER_SHARE_BPS used to stand in ArbiterRegistryFacet — the live
    // declaration has sat in `ArbiterRegistryStorage` since 27 October 2026,
    // read by the vault facet and written by the registry, which is the
    // opposite arrangement).
    /// ── THE APPEAL'S OWN SPAN, AND IT IS BOTH NUMBERS AT ONCE
    ///    (29 October 2026, decision 244 and its amendment of that evening) ──
    ///
    /// FOUR DAYS, and they are the DEADLINE of an ordinary appeal: `raiseAppeal`
    /// stamps the filing plus this span into `appealDeadline`, and that is the
    /// whole clock of every appeal whose panel is summoned on its first seed.
    /// It is ALSO the span the summoned five are guaranteed to read the case in,
    /// so a panel summoned on a RE-THROWN seed is re-stamped with it (see
    /// `summonAppealPanel`), and the door that makes a doomed panel impossible
    /// reserves it at the end of the week (see `_summonsClosesAt`).
    ///
    /// ⚠️ IT WAS "THE WHOLE LIFE OF THE APPEAL" FOR A FEW HOURS ON 29 OCTOBER
    /// 2026, AND THE OWNER TOOK THAT BACK THE SAME EVENING. The first build of
    /// decision 244 read "the limit is a week" as "the deadline is a week", so
    /// the OTHER side's escrow froze for seven days in every appeal — including
    /// one where the lot was pulled in the first minute and nothing whatever
    /// went wrong. It charged three extra days to the party who had no part in
    /// the failure the repair was built for. The week is a CEILING and nothing
    /// else; `APPEAL_TOTAL_WINDOW` below says so in its own words. Marked
    /// rather than deleted, because the wrong version is what 67 money tests of
    /// this tree went red on, and they were right.
    ///
    /// ⚠️ IT IS STILL THE NUMBER `relayer/bagStore.js` MIRRORS, AND THAT
    /// MIRROR IS EXACT AGAIN FOR AN ORDINARY APPEAL AND SHORT FOR A STRETCHED
    /// ONE. The relayer keeps the evidence until the appeal can no longer be
    /// decided, and it computes that moment as "the dispute plus the
    /// finalization delay plus this window". On an appeal summoned from its
    /// first seed both sides are four days and the mirror is right. On the one
    /// shape that moves — the single throw spent late, the deadline re-stamped
    /// at the summons — the decidable moment sits up to three days further out,
    /// and the relayer would drop the evidence while the five are still
    /// reading.
    /// ⚠️ AND THE GATE OVER THAT SEAM CANNOT SEE THE DIFFERENCE:
    /// script/check-appeal-window.sh pins THIS constant against the relayer's
    /// copy, both are four days, so it is green — and for the ordinary appeal
    /// correctly green. Carried to the owner as an unclosed finding rather than
    /// fixed from here: the relayer is a different zone with its own task in
    /// the queue, and the number is his to confirm.
    uint256 private constant APPEAL_REVIEW_WINDOW = 4 days;     // the same span DISPUTE_WINDOW gives the arbiter

    /// ── THE CEILING OVER THE WHOLE AFFAIR, AND NOT THE DEADLINE OF ANY
    ///    APPEAL (29 October 2026, decision 244, the owner's number, as he
    ///    corrected it the same evening) ──
    ///
    /// SEVEN DAYS from the filing. Nothing is stamped with it and no appeal is
    /// given it: it is the limit a re-stamped deadline may never pass, and the
    /// span the summons door is cut out of — the door closes
    /// `APPEAL_REVIEW_WINDOW` before it, which is the third day, so the five
    /// always have their reading time inside the ceiling.
    ///
    /// ⚠️ IT IS NOT WRITTEN INTO `appealDeadline`, AND IT WAS FOR A FEW HOURS
    /// ON 29 OCTOBER 2026. That is the correction of that evening: the deadline
    /// is the filing plus `APPEAL_REVIEW_WINDOW`, re-stamped once if the single
    /// throw is spent late, and clamped by this number. Written into the
    /// deadline it froze somebody else's escrow for a week on EVERY appeal —
    /// see the marked paragraph above.
    ///
    /// ⚠️ A TIMER ON THE THROW AND NOT A SPAN IT LENGTHENS, which is the half
    /// of the rule that is easy to build the other way round. A throw that
    /// bought a week of its own would be a second week of somebody else's
    /// escrow frozen by a man who need do nothing but wait. The throw moves the
    /// deadline INSIDE this ceiling and never past it, and an unspent throw
    /// expires with the summons door rather than outliving it.
    ///
    /// ⚠️ WHAT IT COSTS AND WHO PAYS, RE-PRICED AFTER THE CORRECTION: the
    /// other side's money is locked for FOUR days in an ordinary appeal, which
    /// is what it was before decision 244 touched anything, and for up to seven
    /// only where the appellant really did spend his one throw late — and then
    /// only by as much as the five need to read the case. That is less than
    /// this decision was spending an hour earlier, not more.
    uint256 private constant APPEAL_TOTAL_WINDOW = 7 days;

    /// ── HOW MANY TIMES THE LOT MAY BE THROWN AGAIN ──
    ///
    /// ONE. The appellant chooses between TWO panels in all, and that is the
    /// owner's number of the evening of 29 October 2026.
    ///
    /// ⚠️ IT WAS THREE EARLIER THE SAME DAY, AND IT CAME DOWN ON A PRICE THAT
    /// WAS MEASURED RATHER THAN FEARED. The five are computable the moment the
    /// seed's block is mined — the hash and the frozen roster decide them, and
    /// the summoning transaction contributes nothing — so every throw is a
    /// fresh ticket in a lottery whose numbers the buyer can already read. What
    /// that buys an appellant who controls a share `p` of the enfranchised
    /// corps, as the chance of seating three of his own men on a panel of five:
    ///
    ///   p      one panel   best of 2   best of 4
    ///   0.20     5.8%        11.2%       21.2%
    ///   0.30    16.3%        29.9%       50.9%
    ///
    /// Three throws took a man holding under a third of the corps to BETTER
    /// THAN A COIN FLIP. One throw keeps the repair and leaves the odds within
    /// a factor of two of the single draw the protocol was designed around.
    ///
    /// ⚠️ AND THE SECOND ARGUMENT IS THE ONE THAT WAS MISSING WHEN THREE WAS
    /// CHOSEN: THROWS DO NOT CURE A RELAYER THAT IS DOWN. If the relayer missed
    /// the first window because it is lying down, it is still lying down for the
    /// second and the third — the three attempts fail together, because they
    /// fail for the same reason. Throws cure a window MISSED BY CHANCE; an
    /// outage is cured by the door being permissionless and by the appellant's
    /// own wallet, both of which it already is. So the second and third tickets
    /// were paying for an outcome they could not deliver.
    ///
    /// ⚠️ A FLOOR OR A CEILING ON THE CORPS SIZE WAS REFUSED, and not as a
    /// matter of taste: decision 174 forbids it, and it would buy nothing here
    /// anyway — the capture probability above depends on the SHARE a man holds,
    /// not on how many seats there are.
    ///
    /// One cycle of throw-wait-compute-expire is about 261 blocks, some 52
    /// seconds at the chain's present speed, so an UNCOUNTED throw inside the
    /// summons window would have been about five thousand tickets. The count is
    /// therefore the whole of the protection, which is why it is one literal
    /// and has an argument beside it.
    uint256 private constant APPEAL_MAX_RE_ROLLS = 1;

    /// ── THE SEATS DO NOT OPEN IN THE BLOCK THE APPEAL IS RAISED
    ///    (24 September 2026, the owner's decision) ──
    ///
    /// First come, first served is what makes the panel cost nothing to
    /// assemble, and it is also its one practical weakness: a pair of bots
    /// watching the mempool can take all three seats in the same block the
    /// appeal is raised, and no arbiter who reads cases like a person ever sees
    /// the case at all. That is not collusion being solved — collusion is
    /// answered by the case bond, the mistake streak and every vote being
    /// public — it is the RACE being taken out of the first instant.
    ///
    /// An hour out of a window of four days is 1/96 of it. What it buys is that
    /// the appeal is on the board, visible, before anybody can close it.
    ///
    /// DECLARED ONCE. The door and the view both read `_seatsOpenAt`, never the
    /// arithmetic — two copies of one rule agree until the first edit.
    uint256 private constant APPEAL_SEAT_DELAY = 1 hours;

    /// ── FIVE SEATS, AND THREE VOTES OVERTURN (decision 177, 14 October
    ///    2026) ──
    ///
    /// ⚠️ FIVE IS HOW MANY THE CHAIN SUMMONS, AND IT STOPPED BEING A CAP ON
    /// ARRIVALS ON 14 OCTOBER 2026, when the lot was built. The sentence that
    /// stood here said the opposite — "five is a cap and not a summons" — and
    /// it was true for the hours between the two halves of 177 landing. A seat
    /// is no longer taken by pressing first: `summonAppealPanel` draws five
    /// arbiters BY NUMBER out of the corps, writes them down, and
    /// `voteToOverturn` refuses everybody else with `NotOnAppealPanel`.
    ///
    /// WHAT THE LOT BUYS, as a price and not as an adjective. Before it,
    /// capturing a panel cost THREE ARBITERS AT ANY CORPS SIZE: three
    /// addresses that agreed in advance pressed first and the panel was
    /// theirs, whether the corps held four or four hundred. After it, the five
    /// are a sample of the corps, so a circle holding a share `k/N` of the
    /// corps expects `APPEAL_PANEL_SEATS * k / N` seats and needs `k/N >= 3/5`
    /// before it can expect the bar. The price of capture became proportional
    /// to the SHARE of the corps, and a share is the one thing that cannot be
    /// bought cheaply here: the seat itself is about six dollars, but the
    /// arbiter behind it takes five different clients, fifty points from each
    /// and sixteen days of calendar to manufacture. The expectation and the
    /// hypergeometric tail are measured against the real draw in
    /// test/AppealLotPrice.t.sol rather than asserted here.
    ///
    /// ⚠️ WHAT THE LOT DOES NOT BUY, named so that nobody reads the paragraph
    /// above as a solved problem: it prices ONE attempt. An attacker who
    /// manufactures cheap deals can raise many appeals and pursue only the
    /// ones whose draw favoured him.
    ///
    /// ⚠️ AND THE TWO SENTENCES THAT STOOD HERE ARE BOTH WRONG NOW RATHER THAN
    /// MERELY DATED (corrected 18 October 2026, kept marked because the shape
    /// of the worry is still the right shape). They read "and the deposit comes
    /// home on the ones he abandons" and "what answers repetition is a price
    /// that GROWS on the voter, which is a separate piece of work and is not
    /// built".
    ///
    /// The deposit comes home on NOTHING. The owner's decision of 17 October
    /// 2026 left it no road back in any branch, and an abandoned attempt is
    /// exactly the branch where the WHOLE of it goes to the TREASURY
    /// (`_nobodyAnswered`; it crossed to the other side of the deal from the
    /// 17th until 19 October 2026) — so every abandoned attempt costs him the
    /// whole deposit, which is the bill the old sentence said he escaped.
    ///
    /// The price that grows on the voter IS built, on 18 October 2026:
    /// `ArbiterRegistryStorage.appealVoteFeeAgainst`, keyed on the PAIR (voter,
    /// the judge he votes against), charged by `voteToOverturn` into the bank,
    /// nought for the first vote of a run and then 10, 20, 40, 80 USDC inside a
    /// 30-day window. Measured in test/AppealVoteRepeatFee.t.sol. The pointer
    /// at the project's journal of known and unfixed things went with it; the
    /// discipline it was written under stands for whatever replaces it — that
    /// journal does not travel to the public mirror, so naming its path here
    /// would send a reader there to a document they cannot open.
    ///
    /// ⚠️ WHAT IS STILL NOT BOUGHT, measured on this tree and not reasoned
    /// about. Of the three doors a growing price was meant to stand at, only
    /// the voter's is built: there is no growing price on the man who RAISES an
    /// appeal and none on the man who OPENS a dispute, and no counter for
    /// either exists under src/. The appellant pays a flat deposit however
    /// often he comes back. And on a deal where ONE man holds both sides, the
    /// deposit comes back to the pocket it left in the branch where he WINS.
    ///
    ///     ⚠️ THIS PARAGRAPH ALSO NAMED THE ABANDONED BRANCH — "the deposit
    ///     crosses into his own other pocket" — AND THAT ROAD WAS CLOSED ON
    ///     19 OCTOBER 2026. Silence now credits the treasury, which no second
    ///     key can be, so an unread appeal costs him the whole deposit at any
    ///     number of addresses. The WON branch is untouched and is still a
    ///     refund to whoever paid.
    ///
    /// ⚠️ BUT THE VOTE FEE IS NOT THE ONLY CHARGE THAT LEAVES HIS CIRCLE, AND
    /// THIS SENTENCE SAID IT WAS UNTIL 18 OCTOBER 2026. Three charges leave it,
    /// each under its own condition, and the deposit is the only one of them
    /// that can come back:
    ///   • the DISPUTE FEE, always, and before an appeal exists at all. The
    ///     fee is taken out of the POT — on a deal he funded on both sides,
    ///     out of his own money — at 3% of it with DISPUTE_FEE_CAP as the
    ///     ceiling (`Agreement.disputeFee()`), and no branch sends it back. On
    ///     the verdict he then overturns, the share the judge forfeits goes to
    ///     the arbiter bank (`ArbiterVaultFacet._settleForfeitedShare`,
    ///     `d.vaultBalance += share`) and the protocol keeps its levy in the
    ///     treasury. Neither destination is his.
    ///   • THE WHOLE DEPOSIT, whenever his appeal did NOT carry and at least
    ///     one summoned arbiter answered: three quarters of it become the
    ///     panel's wage, divided among those who answered, the last quarter
    ///     crosses to the other side of the deal, and none of it is his any
    ///     more. ⚠️ THIS ROW READ "HALF THE DEPOSIT" UNTIL 18 OCTOBER 2026
    ///     (evening): the owner moved the money onto the OUTCOME, so a lost
    ///     appeal now costs him twice what it did and a WON one costs him
    ///     nothing at all — the deposit goes home and the panel is paid out of
    ///     the overturned judge's bond. ⚠️ AND THE SPLIT INSIDE IT IS OF
    ///     19 OCTOBER 2026: what leaves his circle on a lost appeal is the
    ///     whole deposit whatever seats he holds, where a circle holding one
    ///     of the panel's seats used to recover all of it as a wage.
    ///   • the VOTE FEE, whenever he casts a repeat vote against the same
    ///     judge inside the window.
    /// ⚠️ AND THE ABANDONED ROUND STOPPED BEING THE CHEAP ONE ON 19 OCTOBER
    /// 2026. This paragraph read "the cheap round is the abandoned one: an
    /// attempt nobody answers costs him the dispute fee and nothing else,
    /// because the deposit crosses to his own other pocket whole and no vote of
    /// his was ever charged for". The first half was measured and true; the
    /// reason was the crossing, and the crossing is gone. Silence now credits
    /// the treasury, so an abandoned attempt costs him the dispute fee AND the
    /// whole deposit, at any number of addresses. What is still cheap about it
    /// is only that no vote of his was charged for.
    ///
    /// Neither the new deposit rule nor the ladder is mounted on the live
    /// diamond yet; the measurement that says so, with its date, is written
    /// over the retired per-address fee fields in `ArbiterRegistryFacet`.
    ///
    /// THE HISTORY, kept because both retired rules explain this one. The
    /// quorum began as a flat `APPEAL_MIN_VOTES = 3`; on 18 September it became
    /// `min(CAP, eligible voters)` with this floor, counted by walking
    /// `arbiterList` at the moment the appeal was raised. That count was the
    /// defect: part 2 of this branch let anybody with five clean deals seat
    /// himself, nothing caps the corps, and the walk was paid for BY THE
    /// APPELLANT — 150 029 gas at four seats, 2 546 205 at five hundred,
    /// measured in test/AppealPanelGas.t.sol. The price of challenging a
    /// verdict grew with the number of people entitled to review it.
    ///
    /// THE RULE NOW. The lot calls at most APPEAL_PANEL_SEATS arbiters, once,
    /// in one transaction anybody may send, and only they may vote. Nothing
    /// walks the roster at any door — the five are taken BY NUMBER out of a
    /// frozen N (`summonAppealPanel`, Floyd's F2, exactly five iterations and
    /// at most ten comparisons), and whether THIS man may sit is still asked
    /// of him alone, by `_mayVoteOnAppeals` and the two party checks in
    /// `voteToOverturn`. Whether the verdict was overturned is answered at the
    /// END of the review window instead of guessed at its start, and if fewer
    /// than APPEAL_OVERTURN_VOTES voted the verdict stands. ⚠️ AND THE DEPOSIT
    /// FOLLOWS THAT OUTCOME AND NOTHING ELSE (the owner, 18 October 2026,
    /// evening): a verdict left standing spends it — three quarters of it the
    /// wage of whoever answered the summons and the last quarter across to the
    /// other side of the deal, or the WHOLE of it to the TREASURY when nobody
    /// answered at all (the owner, 19 October 2026; it crossed to the other
    /// side until then) — and a verdict OVERTURNED sends it home whole, the
    /// panel then being paid three quarters of the overturned judge's case bond
    /// with the last quarter going to the treasury. ⚠️ THIS PARAGRAPH HAS
    /// CARRIED THREE WRONG VERSIONS IN TWO DAYS: "the deposit goes home whole"
    /// on every outcome until the morning of 18 October, "half to the other side
    /// of the deal, the rest the wage" until that evening, and "the whole of one
    /// pocket is the wage" until 19 October — the split into a wage and a toll
    /// is the owner's decision of that day, and the quarter is what makes a junk
    /// appeal cost its author something at ANY turnout.
    ///
    /// ⚠️ THE LOT ASKS ONE OF THE FOUR QUESTIONS AND IS BLIND TO THE OTHER
    /// THREE (decision 187, 16 October 2026). This paragraph said "THE LOT IS
    /// BLIND" until that day and is corrected rather than deleted, because the
    /// argument it carried still decides the three the draw does not ask.
    ///
    /// Of the four reasons a summoned man may turn out unable to vote — he is
    /// the ruling arbiter, he is a party to the deal, he is suspended, or he
    /// holds no franchise at all — the draw now asks the LAST, through
    /// `_mayVoteOnAppeals`, the very helper `voteToOverturn` reads. The other
    /// three stay at the door, and the old argument is why: each is a fact
    /// about THIS APPEAL or about a status that can still change between the
    /// draw and the vote, so asking it at the draw would copy an admission
    /// rule into a second place and buy no usable seat.
    ///
    /// WHY THE FOURTH IS NOT LIKE THEM. It is not a fact about the appeal at
    /// all: it is a standing property of the man, it only ever goes from false
    /// to true, and it is SILENT. A self-seated arbiter who has never carried
    /// a case (`applyAsArbiter` leaves `seatedBy` zero, the mark of "seated by
    /// nobody") reads like any other seat on `getAppealSummons`, counts in
    /// `appealSummoned`, and cannot cast the vote the bar is asking him for.
    /// The appellant has already paid his deposit and finds out by watching
    /// the window expire, with nothing anywhere naming the reason. The other
    /// three are loud by comparison — the judge and the parties are on the
    /// deal, a suspension is on the record.
    ///
    /// ⚠️ AND IT COSTS NOTHING IN SHAPE, which was the other half of the old
    /// argument: a seat this question refuses is a LOST SEAT, exactly like a
    /// grave, and never a candidate the draw goes looking to replace. Five
    /// iterations before, five after — the summons does not grow with how many
    /// it rejects. What it costs in gas is one cold SLOAD per seat that gets
    /// that far, re-measured and re-signed at
    /// test/AppealPanelGas.t.sol:SUMMON_CEILING.
    ///
    /// The honest arithmetic with that one question asked: every seat the lot
    /// writes down holds the franchise, and the number of those who may vote
    /// on THIS appeal is what is left after the graves, the parties, the
    /// suspended and the judge. The bar is three.
    ///
    /// ⚠️ WHAT THAT MEANS AT A CORPS OF FOUR, which is what the live chain
    /// holds on the day this lands, counted and not softened: the lot calls
    /// ALL FOUR (a corps at or below the seats is summoned whole), and one of
    /// the four is the arbiter whose verdict is under appeal — he is refused
    /// by `CannotVoteOnOwnVerdict`. Three may vote and the bar is three, so
    /// ONE silence buries the appeal. That is the price of the owner's choice
    /// of five-and-three at this corps size, and 177 says to record it rather
    /// than patch it; it falls away by itself as the corps grows, which the
    /// open seat makes cheap.
    ///
    /// WHY A CEILING AT ALL, rather than letting the whole corps vote: a corps
    /// of hundreds all voting on one appeal is the same unbounded cost moved
    /// from the appellant onto the arbiters and onto the payout, and the pay
    /// per voter would fall to dust.
    ///
    /// ⚠️ WHY THE CEILING IS ABOVE THE BAR, SAID OUT LOUD because the two
    /// numbers used to be one. 177: five are summoned so that the silence of
    /// two does not bury the appeal — at three seats and a bar of three, one
    /// arbiter who never comes kills every appeal, and killing an appeal by not
    /// turning up would cost nothing. Redundancy cannot be turned into a
    /// weapon; a penalty for silence can, which is why 177 refused one.
    ///
    /// WHAT THE SEATS NEVER DEFENDED, kept because it explains what changed
    /// and what did not. Until the lot, seats did not stop a circle that had
    /// agreed in advance, and "first come" made a determined group FASTER
    /// rather than slower; collusion was answered only by the case bond, the
    /// mistake streak, every vote being public, and the bar of three. The lot
    /// is the first thing here that makes the circle's size matter: it still
    /// does not stop collusion, it prices it. Everything else on that list
    /// stands.
    uint256 private constant APPEAL_PANEL_SEATS = 5;
    /// ── THREE VOTES OVERTURN A VERDICT, AND THERE IS NO SECOND DIRECTION
    ///    (decision 177, 14 October 2026) ──
    ///
    /// Not a quorum and not a floor, which is what the number standing here
    /// used to be (`APPEAL_VOTES_FLOOR = 2`, "fewer than this and no panel
    /// assembled"). It is THE BAR: this many votes to overturn and the verdict
    /// flips; anything less and it stands. Nobody votes the other way — there
    /// is no other way to vote.
    ///
    /// WHY THREE AND NOT TWO (177's own argument, recorded not re-derived):
    /// manufacturing a registered arbiter is the expensive part of capturing a
    /// panel, so asking for a third vote raises the price of capture by half,
    /// and it is one literal on this line.
    ///
    /// ⚠️ IT IS NOT A DOOR CONDITION, and that moved the moment the roster walk
    /// went (23 September 2026). It used to be checked ABOVE the transfer in
    /// `raiseAppeal`, so a corps too small to review anything could not take
    /// the appellant's money. Nothing can be counted at that door any more, so
    /// the money IS taken and comes back at `resolveAppeal` instead.
    uint256 private constant APPEAL_OVERTURN_VOTES = 3;

    /// ── HOW FAR AHEAD THE LOT'S SEED IS FIXED (the lot, 14 October 2026) ──
    ///
    /// `raiseAppeal` writes `block.number + this` into the appeal and nothing
    /// else; the seed is `blockhash` of that height, read later by
    /// `summonAppealPanel`. At the moment the appellant presses, the hash of a
    /// block five ahead is zero for everybody — it does not exist — so he
    /// cannot pick his panel by picking his moment, which is 177's first
    /// requirement of the lot.
    ///
    /// WHY FIVE AND NOT ONE. One block would already be unknowable to the
    /// appellant, and five is for the room between a transaction being signed
    /// and landing: it costs about ten seconds on Base and buys that the seed
    /// block is unambiguously after the raise even if the raise lands a block
    /// or two late.
    ///
    /// ⚠️ WHAT IT DOES NOT DEFEND AGAINST, said out loud because the number
    /// looks like a security margin: Base's sequencer is a single party and it
    /// builds the block the seed comes from, so a sequencer willing to discard
    /// its own block could grind the hash. No delay fixes that — it is a
    /// property of the chain this protocol runs on. It is written down in the
    /// project's journal of known and unfixed things rather than argued away
    /// here; the path is not named, for the reason given over
    /// APPEAL_PANEL_SEATS.
    uint256 private constant APPEAL_SEED_DELAY_BLOCKS = 5;

    /// ── HOW LONG THE SEED LIVES, AND IT IS NOT OUR CHOICE ─────────────────
    ///
    /// `blockhash` answers for the last 256 blocks and ZERO beyond them. On
    /// Base, at two seconds a block, that is about eight and a half minutes
    /// from the seed height — the whole window in which this appeal's panel
    /// can be summoned.
    ///
    /// ⚠️ ZERO IS A REFUSAL HERE AND NEVER A VALUE. A seed of zero draws a
    /// panel anybody can compute in advance, and it looks exactly like a
    /// normal one, so `summonAppealPanel` never draws past the horizon: it
    /// turns to the throw-again branch BEFORE it reads the hash — and for an
    /// appeal filed before that branch existed it still refuses by the old name
    /// (`AppealSeedExpired`) — and refuses a zero hash
    /// inside the window as well (`AppealSeedUnavailable`) rather than
    /// trusting the arithmetic above it.
    ///
    /// ⚠️ THE PARAGRAPH THAT STOOD HERE — "WHY IT IS NOT A SECOND CHANCE" —
    /// WAS OVERTURNED BY THE OWNER ON 29 OCTOBER 2026 (decision 244), AND ITS
    /// ARGUMENT WAS NOT WRONG, IT WAS PRICED. It read: "Re-drawing instead
    /// would hand an attacker a free re-roll: wait for the seed to go stale,
    /// draw again, and keep drawing until the five fall his way, at the price
    /// of patience. An honest appellant needs one transaction inside eight
    /// minutes, his own browser sends it, and anybody at all may send it for
    /// him."
    ///
    /// Two of its three premises were measured and both had moved. "Eight
    /// minutes" is FIFTY-ONE SECONDS at the 0.2-second block the chain has run
    /// since 21 October 2026, which the owner called impossible for a man who
    /// has to open a page and connect a wallet. And "at the price of patience"
    /// is now a NAMED price instead of an open one: ONE throw, so two panels in
    /// all, inside one absolute week — where an uncounted re-draw really would
    /// have been thousands of tickets. The third premise, that the five are
    /// computable in advance, is true and is what makes the COUNT the whole of
    /// the protection — see `APPEAL_MAX_RE_ROLLS` for the capture odds that set
    /// the number at one rather than three.
    ///
    /// What a missed window costs today: the panel does not assemble on that
    /// seed, the appellant may throw again if he has a throw left, and when he
    /// has not, `resolveAppeal` settles at once with the verdict standing — see
    /// the dead-panel branch there.
    ///
    /// ⚠️ A SEED THAT WENT STALE COSTS THE APPELLANT HIS WHOLE DEPOSIT, and
    /// since 17 October 2026 it needs no argument of its own: nobody answered,
    /// so there is no panel to pay, so all of it goes where every silent
    /// appeal's deposit goes — the TREASURY since 19 October 2026, and the
    /// party who did not appeal before that.
    /// ⚠️ IT USED TO NEED ONE, and losing that is the point: decision
    /// 179 burned the deposit when not one of the summoned voted, and this path
    /// had to be told apart from that one by reading the summons count, because
    /// one of the two charged him and the other did not. Both charge him now.
    /// The rule lives in `_nobodyAnswered`.
    uint256 private constant APPEAL_SEED_HORIZON_BLOCKS = 256;

    /// What an appeal cost before its price was written next to it — the
    /// flat 20 USDC in force until 26 August 2026. Read by `_depositOf` and by
    /// nothing else.
    ///
    /// ⚠️ NOT THE FLOOR OF TODAY'S PRICE, AND SINCE 20 OCTOBER 2026 THE TWO ARE
    /// NO LONGER EVEN EQUAL — which is the first day this constant earns its
    /// keep rather than merely arguing for it. Since 17 September 2026 an
    /// appeal is priced by `ArbiterRegistryStorage.appealDepositFor` (floor
    /// THIRTY, 3% of the pot, cap 200). Reading that floor here instead would
    /// bring back the defect the receipt field was written to kill: a man who
    /// paid twenty under the old rule would now be refunded thirty, ten
    /// dollars of somebody else's money for a price he never paid. The day the
    /// floor moved is the day that stopped being hypothetical.
    uint256 private constant APPEAL_DEPOSIT_BEFORE_RECEIPT = 20_000_000;

    // ── THE PRICE OF AN APPEAL IS SPLIT: A WAGE AND A TOLL ──────────────────
    //
    // The owner's decision of 19 October 2026, and it is a compromise rather
    // than a preference: three requirements held one at a time and not
    // together.
    //
    //   a junk appeal must COST its author something at any turnout;
    //   what a man earns for READING one must not depend on how he decides it;
    //   a right appellant must come out at EXACTLY nought.
    //
    // The price itself (`ArbiterRegistryStorage.appealDepositFor` — floor 20,
    // 3% of the pot, cap 200, and NO pot ceiling since 20 October 2026) does
    // not move. What moves is how the settlement
    // divides it: THREE QUARTERS are the wage of the men who answered, and the
    // remaining quarter is a TOLL that leaves the appellant's circle.
    //
    // ⚠️ WHY A PART THAT CANNOT COME BACK TO HIM IS THE WHOLE OF IT, measured
    // rather than argued. With the entire pocket paid out as a wage, a junk
    // appeal costs a circle holding ONE SEAT exactly nought: the attacker is
    // paid as a READER, not refunded as an appellant, so the refund rule — which
    // only sends money home on an appeal that CARRIED — never reaches him. That
    // is item 322, locked as an equality at zero in test/AppealPanelWage.t.sol
    // before this split existed. A quarter that goes somewhere he does not own
    // prices that attack at a quarter of the price, at ANY turnout, which is the
    // arithmetic decision 174 asks a defence to be.
    //
    // ⚠️ AND THE WAGE IS THE SAME FRACTION OF BOTH POCKETS, WHICH IS A
    // WEAKER CLAIM THAN "the same number" AND IS THE ONE THAT IS TRUE. Three
    // quarters of the price when the verdict stands, three quarters of the
    // overturned judge's bond when it falls — one fraction, two pockets.
    //
    // AT AND ABOVE A 20 USDC POT the two pockets are one number, so a reader's
    // wage is one number whichever way he decides and he has nothing to earn by
    // deciding either way. BELOW that pot they are not one number: the pot
    // ceiling sits on `caseBondFor` alone, so the bond is the pot while the
    // price stays at its floor, and leaving a bad verdict standing pays MORE
    // than correcting it. That inequality is a PRICE the owner was shown and
    // chose, not an oversight; the argument and the per-pot figures are in the
    // docstring on `replyNoOverturn` further down this file, which has said so
    // correctly since the 20th while this paragraph did not.
    //
    // ⚠️ THIS PARAGRAPH CLAIMED THE BLINDNESS WAS UNCONDITIONAL FOR ONE DAY,
    // and the retired wording is kept rather than overwritten because it is the
    // plausible one to write again: "and since 19 October one sizer prices both
    // — so a reader's wage is one number whichever way he decides". One sizer
    // did price both, for a day. What that cost was measured the next morning:
    // the appeal price lost its 20 USDC floor wherever the pot was smaller,
    // taking with it the only brake on a junk appeal against a dust deal. The
    // owner's decision of 18 October — "the bond only" — was confirmed on
    // 20 October 2026 and there are two sizers again (commit 8008921e).
    //
    // Held by name in test/AppealWageIsOutcomeBlind.t.sol, BOTH halves: the
    // equality at and above the floor, and the inequality below it with the gap
    // derived by hand on each of the four pots that exist on the chain.
    //
    // ⚠️ WHERE THE TOLL GOES DEPENDS ON THE OUTCOME, and the two addressees are
    // named in `resolveAppeal` with the argument for each. It is never the
    // ARBITER BANK: the corps must not earn out of complaints about the corps
    // (the decision on section 2 of this protocol), and a deposit that fed the
    // pot the panel draws from is the defect item 303 was written for.
    //
    // ⚠️ ON A DUST POT THREE QUARTERS TRUNCATE TO NOUGHT, AND THAT IS STATED
    // HERE BECAUSE IT IS THE CORNER A READER WILL LOOK FOR. The pocket on an
    // OVERTURN is the judge's bond, and the pot ceiling on `caseBondFor` lets
    // that be as little as ONE base unit, and `1 * 3 / 4` is nought:
    // the men who read such an appeal are paid nothing, `voterShare` is written
    // as nought, and `getAppealShareOwed` answers nought — so NO CLAIM IS
    // RAISED AGAINST MONEY NOBODY PUT DOWN. The whole base unit leaves as the
    // toll, because the toll is what the division could not pay out, and the
    // identity "what came in at the door went out at the settlement" holds to
    // the base unit on every pot. Measured in
    // test/ArbiterRemovalByCapturedPanel.t.sol and in
    // test/AppealWageIsOutcomeBlind.t.sol.
    //
    // ⚠️ THE OTHER POCKET CANNOT TRUNCATE AT ALL SINCE 20 OCTOBER 2026, and
    // the sentence here used to blame the PRICE for this corner. A verdict left
    // standing divides the appellant's deposit, and that has a 20 USDC floor
    // again, so `3 / 4` of it is never nought. Only the bond road reaches the
    // dust, which is also the only road on which a panel's pocket depends on a
    // pot the panel did not choose.
    uint256 private constant APPEAL_WAGE_NUMERATOR   = 3;
    uint256 private constant APPEAL_WAGE_DENOMINATOR = 4;

    /// The FEWEST votes that can ever decide an appeal — the number the cap on
    /// the chief's bloc is measured against (16 August 2026).
    ///
    /// ⚠️ IT IS NOW THE BAR ITSELF, AND THE MAJORITY ARITHMETIC THAT USED TO
    /// STAND HERE IS GONE (decision 177, 14 October 2026). It was
    /// `APPEAL_VOTES_FLOOR / 2 + 1` = 2, because an appeal was settled by a
    /// strict majority of the votes CAST and two of three cast were a majority.
    /// There is no majority any more: votes have one direction, so the fewest
    /// that can decide anything is exactly the number that overturns.
    ///
    /// WHAT THAT DOES TO THE PROPERTY IT GUARDS, said plainly because the
    /// number went UP and a reader could take that for a tightening. The
    /// property is "the chief's bloc does not decide an appeal", and a bloc
    /// strictly smaller than the bar cannot overturn anything — so the safe
    /// bloc is now two rather than one. That is a LOOSENING in absolute terms
    /// and the property is unchanged: two votes out of a bar of three decide
    /// nothing, where two out of a majority of two decided everything.
    ///
    /// DERIVED, not written as a number: two values about one rule would drift
    /// apart silently — the same class as MISTAKE_THRESHOLD in
    /// ArbiterAccountabilityFacet, declared as a subtraction rather than a
    /// literal.
    uint256 private constant APPEAL_DECIDING_VOTES = APPEAL_OVERTURN_VOTES;

    /// XP taken for ONE proven judicial mistake. It came here with
    /// `_slashArbiterXP`, whose only caller left in the tree is `resolveAppeal`
    /// below: `overturnVerdict` was the other one and left with the owner's
    /// hand on 9 October 2026. Not to be confused with DEMOTION_XP_RESET,
    /// which was deleted on 21 September 2026 — the note where it stood is
    /// still in ArbiterRegistryFacet.
    uint256 private constant OVERTURN_XP_SLASH  = 200;       // XP penalty on an overturn

    // -------- ERC-2771 SENDER --------

    /// The same eight lines as `ArbiterRegistryFacet._msgSender`, copied here
    /// with the doors that moved. Facets of a diamond do not inherit from one
    /// another, so every one of them declares this for itself — the same
    /// arrangement ArbiterVaultFacet, ArbiterAccountabilityFacet and
    /// ArbiterApplicationsFacet already carry. The forwarder it trusts is read
    /// from `FactoryStorage`, which is one slot shared by all of them, so a
    /// forwarder swap reaches this facet without a cut.
    function _msgSender() internal view returns (address sender) {
        address forwarder = FactoryStorage.store().trustedForwarder;
        if (msg.sender == forwarder && msg.data.length >= 20) {
            assembly { sender := shr(96, calldataload(sub(calldatasize(), 20))) }
        } else {
            sender = msg.sender;
        }
    }

    // -------- WHO MAY SIT ON A PANEL --------

    /// Who may vote on somebody else's verdict.
    ///
    /// ⚠️ THE SEAT IS FREE NOW, SO THE SEAT CANNOT BE THE ANSWER. A paid vote
    /// on an appeal, reachable by anybody willing to fill a corps with
    /// addresses, is the hole a free seat opens; the bond used to be what stood
    /// in the way. The owner's replacement is a record of WORK: one case of his
    /// own, carried to a verdict that stood (`cleanVerdicts`, incremented in
    /// `finalizeVerdict` on the branch where the verdict was not overturned).
    ///
    /// It is not money on purpose. Nothing sits above the panel, so a bad vote
    /// has nothing to be punished with — and a price on the vote would filter
    /// out the poor rather than the dishonest.
    ///
    /// ⚠️ THE BOOTSTRAP IS `seatedBy != 0` AND IT IS LOAD-BEARING. On the day
    /// this lands the chain holds four hand-seated arbiters and no clean verdict
    /// counted for the purpose; without this half, the first appeal ever raised
    /// would have nobody at all entitled to review it. A hand-seated arbiter was
    /// chosen by a person who answers for the choice — that is the standing the
    /// counter would otherwise have to prove.
    ///
    /// ⚠️ IT IS NEVER ASKED OF THE ROSTER (23 September 2026).
    /// `_eligibleVoterCount` used to call this in a loop over `arbiterList` at
    /// the appellant's expense; that loop is gone and must not come back.
    ///
    /// ⚠️ "OF ONE MAN" BECAME "OF AT MOST FIVE" ON 16 OCTOBER 2026 (decision
    /// 187), and the sentence that stood here — "the only caller is
    /// `voteToOverturn`" — is corrected rather than deleted, because the bound
    /// is the point and not the count. There are two callers now:
    ///
    ///   • `voteToOverturn`, on the arbiter pressing the button;
    ///   • `summonAppealPanel`, on each of the seats the lot draws — five
    ///     iterations at any corps size, fixed by APPEAL_PANEL_SEATS and not
    ///     by how many arbiters exist.
    ///
    /// The forbidden shape is a walk whose length follows the corps, and five
    /// is not one. Add a third caller only on the same terms.
    function _mayVoteOnAppeals(ArbiterRegistryStorage.Data storage d, address who)
        private
        view
        returns (bool)
    {
        return d.seatedBy[who] != address(0) || d.cleanVerdicts[who] != 0;
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

    /// What THIS appeal was paid with (26 August 2026). One owner
    /// for the rule, read by both ends of resolveAppeal — the refund and the
    /// forfeit — so they can never disagree about the same money.
    ///
    /// ⚠️ A NOUGHT HERE MEANS ONE THING AGAIN (20 October 2026), AND THE
    /// SECOND MEANING IS KEPT RATHER THAN DELETED. For one day a price of
    /// nought was possible: the pot ceiling sat on `appealDepositFor` and took
    /// the 20 USDC floor off wherever the pot was smaller, so a nought in
    /// `appealDeposit` meant one of two opposite things and the old fallback
    /// would have divided twenty dollars NOBODY PUT DOWN out of the diamond's
    /// escrow — to a panel where the verdict stands, or to the appellant as a
    /// refund where it falls. The owner's decision of 18 October, confirmed on
    /// 20 October, put the ceiling back on `caseBondFor` alone, so the price is
    /// never below its floor and the flag is never set.
    ///
    /// ⚠️ THE FLAG BRANCH IS UNREACHABLE AS OF 20 OCTOBER 2026, AND IT STAYS.
    /// `appealDepositFor` starts at `APPEAL_DEPOSIT_FLOOR` and only ever raises
    /// it, so `raiseAppeal` cannot write a nought price and nothing sets the
    /// mapping; and no appeal anywhere ever carried the flag, because the day
    /// it became writable never reached the chain (last cut broadcast
    /// 16 October 2026). WHAT WOULD REVIVE IT: any change that lets the price
    /// fall to nought — moving the pot ceiling back onto `appealDepositFor`,
    /// dropping `APPEAL_DEPOSIT_FLOOR` to nought, or making the floor
    /// conditional on anything a caller controls. Until then this is a decode
    /// of a state nobody is in. ⚠️ NOTHING OF IT IS DELETED: the mapping keeps
    /// its slot (the layout is append-only and a field is never taken back
    /// out), and the three-state read below stays whole, because the branch
    /// that IS live — `paid == 0`, flag clear — is the one that keeps an appeal
    /// raised before the receipt existed resolvable.
    ///
    /// THE THREE STATES, AND THE ORDER OF THE READS IS THE DECODE:
    ///
    ///   `paid != 0`                     → a real price, and it IS the answer
    ///   `paid == 0`, flag set           → a real nought: priced, at nothing
    ///   `paid == 0`, flag clear         → raised before the price was
    ///                                     recorded; the flat rule applies
    ///
    /// ⚠️ THE PRICE IS ASKED FIRST, AND THAT IS NOT MERELY TIDY. On every
    /// ordinary appeal `paid` is non-nought, so this function returns without
    /// ever SLOADing the flag — which is the other half of why the flag costs
    /// the appellant nothing. The expensive read happens only where the price
    /// was nought, and that road needs a manufactured contract.
    ///
    /// ⚠️ WHERE THE FLAG IS CLEAR, THE OLD RULE STANDS UNCHANGED, and that is
    /// the half a reader is most likely to simplify away. An appeal raised
    /// before this mapping existed must stay RESOLVABLE — an appeal already
    /// paid for must not become unresolvable, or unpriced, because of an
    /// upgrade — so the fallback below is exactly the rule it was raised
    /// under, and it is still deliberately not a revert. Both directions are
    /// held by scenes in test/AppealWageIsOutcomeBlind.t.sol.
    ///
    /// ⚠️ THE FLAG IS READ, NEVER THE FACT THAT THE DEAL IS CHEAP. "The pot
    /// is nought, so the price must be nought" would be a second copy of the
    /// pricing rule living in the refund — and since 20 October 2026 it would
    /// also be the WRONG rule, because the pot sizes the bond and not the
    /// price. What this function answers is a RECEIPT, not a price: what this
    /// man actually put down.
    function _depositOf(
        ArbiterRegistryStorage.Data storage d,
        address agreement,
        ArbiterRegistryStorage.PendingVerdict storage v
    )
        private view returns (uint256)
    {
        uint256 paid = v.appealDeposit;
        if (paid != 0) return paid;
        // The flag arm is unreachable since 20 October 2026 — nothing can set
        // the mapping while the price has a floor. Kept, with the conditions
        // that would revive it, in the docstring above.
        return d.appealPricedAtNought[agreement] ? 0 : APPEAL_DEPOSIT_BEFORE_RECEIPT;
    }

    // -------- APPEAL FLOW (user-initiated, pre-finalization only) --------

    /// @notice The losing party challenges a verdict before the money reaches executor/client.
    ///
    /// ⚠️ THE PRICE IS NO LONGER FLAT (17 September 2026), and both sides of
    /// that argument are kept here rather than the losing one erased.
    ///
    /// The old argument: the deal amount is chosen by the parties, so it
    /// cannot be trusted as the input to anything that can be won or lost —
    /// hence a flat $20 on every deal.
    ///
    /// The argument that won: a flat $20 is a toll on a $100 deal and nothing
    /// on a $10 000 one, where overturning a verdict moves thousands and the
    /// appeal is the cheapest bet in the protocol. The panel is now paid out
    /// of the deposit, so a deposit that does not grow with what is at stake
    /// pays the same three arbiters the same six dollars to read a case of any
    /// size. And the first argument is weaker than it looked: the amount is
    /// the parties' own choice, but it is also the escrow itself — lowering it
    /// to cheapen an appeal lowers the very money the appeal is about, and the
    /// floor holds regardless.
    ///
    /// Decided by the owner: the price is the deal's own dispute fee (3% of
    /// the pot), held between 20 and 200 USDC —
    /// `ArbiterRegistryStorage.appealDepositFor`. What was actually paid is
    /// written into `appealDeposit`, so later changes to the rule reach only
    /// later appeals.
    function raiseAppeal(address agreement) external {
        if (agreement == address(0)) revert ArbiterRegistryFacet.ArbiterZeroAddress();
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (v.submittedAt == 0) revert ArbiterRegistryFacet.NoVerdict();
        if (v.finalized) revert ArbiterRegistryFacet.AlreadyFinalized();
        // Checked before `frozen`: raiseAppeal() itself sets frozen=true as a side effect, so
        // once appealed, frozen is always already true too — checking frozen first would make
        // AlreadyAppealed unreachable on a second call to this same function.
        if (v.appealed) revert ArbiterRegistryFacet.AlreadyAppealed();
        if (v.frozen) revert ArbiterRegistryFacet.VerdictFrozenError();
        // ⚠️ THE WINDOW THIS VERDICT WAS SUBMITTED WITH, not the one in force
        // now (27 October 2026, decision 52). Shortening the constant by a cut
        // used to close the appeal window of EVERY standing verdict in one
        // block, with no transaction the losing party could see, and open its
        // finalization at the same instant — the escrow then pays out on a
        // verdict that can no longer be challenged. See
        // `ArbiterRegistryStorage.finalizeAt`.
        if (block.timestamp >= ArbiterRegistryStorage.finalizeAt(v)) {
            revert ArbiterRegistryFacet.AppealWindowClosed();
        }

        (bool clientOk, bytes memory clientData) = agreement.staticcall(abi.encodeWithSignature("client()"));
        (bool execOk,   bytes memory execData)   = agreement.staticcall(abi.encodeWithSignature("executor()"));
        if (!(clientOk && execOk)) revert ArbiterRegistryFacet.DealPartiesUnreadable();
        address agreementClient   = abi.decode(clientData, (address));
        address agreementExecutor = abi.decode(execData,   (address));

        bool callerIsLosingClient   = caller == agreementClient   && !v.clientWins;
        bool callerIsLosingExecutor = caller == agreementExecutor &&  v.clientWins;
        if (!callerIsLosingClient && !callerIsLosingExecutor) revert ArbiterRegistryFacet.NotLosingParty();

        // ⚠️ NOTHING IS COUNTED HERE ANY MORE (23 September 2026, the owner's
        // decision). Until this edit the line above walked `arbiterList` end to
        // end, two cold reads a seat, to find out whether a panel could
        // assemble — and THE APPELLANT PAID FOR THE WALK. Measured through the
        // real diamond with cold slots, in test/AppealPanelGas.t.sol: 150 029
        // gas at four seats, 613 805 at a hundred, 2 546 205 at five hundred.
        // Part 2 of this branch opened the corps to anybody with five clean
        // deals and put no ceiling on its size, so the price of challenging a
        // verdict was set to grow without bound. An appeal only the rich can
        // afford is not an appeal.
        //
        // The owner's answer was not a cheaper count but no count: the panel
        // has three seats, arbiters take them themselves, and whether two of
        // them are ever taken is settled at the END of the review window rather
        // than guessed at its start. What that costs, said plainly and not
        // discovered later: a deposit is now taken on an appeal that may find
        // no reader at all. It comes back whole when that happens — the
        // no-panel branch of `resolveAppeal`, which already existed and only
        // changed its reason.
        uint256 deposit = ArbiterRegistryStorage.appealDepositFor(agreement);
        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transferFrom(caller, address(this), deposit);
        if (!ok) revert ArbiterRegistryFacet.DepositTransferFailed();

        v.appealed       = true;
        v.frozen         = true;
        v.appellant      = caller;
        // ⚠️ FOUR DAYS FROM THIS MOMENT, AND THE WEEK IS NOT WRITTEN HERE
        // (29 October 2026, decision 244 as the owner corrected it that
        // evening). This field is the one absolute stamp this door leaves on
        // the clock, and what it carries is the filing plus
        // `APPEAL_REVIEW_WINDOW` — exactly what it carried before decision 244,
        // so an appeal whose panel is summoned on its first seed is not moved
        // by any of this work by a single second.
        //
        // ⚠️ IT IS THE ONLY DEADLINE FIELD, AND IT IS RE-STAMPED IN EXACTLY
        // ONE OTHER PLACE: `summonAppealPanel`, and only where the panel was
        // summoned on a RE-THROWN seed, so that five men called late still get
        // their four days. Both writes are absolute stamps, neither reads a
        // constant live, and that is decision 244's point 4 whole — the man
        // never learns from a cut that his deadline became another number. No
        // second deadline field was added: two owners for one number disagree
        // on the first edit to either.
        //
        // ⚠️ SO THE MOMENT THE "NOBODY ANSWERED" SETTLEMENT BECOMES PRESSABLE
        // DOES NOT MOVE on an ordinary appeal, and that is measured rather than
        // asserted: 67 money tests of this tree went red the first time this
        // line said `APPEAL_TOTAL_WINDOW`, and they are the lock on it. The
        // MONEY of that branch is untouched either way — decision 200, the
        // whole price to the TREASURY, nothing back to the appellant.
        //
        // ⚠️ THESE LINES READ "the whole price to the other side of the
        // deal" WHEN THEY WERE WRITTEN ON 29 OCTOBER 2026, and the wording is
        // quoted rather than erased because it is where the confusion comes
        // from: it is decision 200's table row, which is a snapshot of
        // 19 October 2026 taken BEFORE that same evening's correction moved
        // the silent road to the treasury. The row is marked as dated in the
        // record; the branch itself carries the argument, in
        // `_nobodyAnswered`.
        v.appealDeadline = block.timestamp + APPEAL_REVIEW_WINDOW;
        // The money he put down, written next to the appeal it belongs to.
        // Not for reading back the price rule — for paying back
        // THIS man. See PendingVerdict.appealDeposit.
        v.appealDeposit  = deposit;
        // ⚠️ AND ON ONE BRANCH ONLY, A SECOND WRITE SAYING THAT THE NOUGHT
        // ABOVE IS A REAL PRICE. While the pot ceiling sat on this sizer
        // (19-20 October 2026) `deposit` could legitimately be NOUGHT — a pot
        // of nought — and `_depositOf` used to read a nought as "raised before
        // the price was recorded" and substitute the old flat 20 USDC, which is
        // twenty dollars nobody put down.
        //
        // ⚠️ CONDITIONAL, AND THE CONDITION IS THE WHOLE REASON THE APPELLANT
        // PAYS NOTHING FOR IT. Written on every appeal this is one COLD SSTORE,
        // about 22 100, on the door that challenges a verdict — measured at
        // 161 524 against the 145 000 ceiling pinned in
        // test/AppealPanelGas.t.sol, which is a deliberate tripwire and not
        // slack: the note beside it says the next edit to this path must
        // justify itself rather than be absorbed. Twenty per cent on the price
        // of challenging a verdict, for a bit that only ever matters on a
        // manufactured contract, does not justify itself. On this branch alone
        // the ordinary appellant pays for no SSTORE at all, and `_depositOf`
        // does not even SLOAD it — his non-nought `appealDeposit` answers
        // first.
        //
        // ⚠️ SO THE FLAG SAYS "PRICED AT NOUGHT", NOT "PRICED", AND ITS NAME
        // SAYS SO. Nothing may read it as "a price exists": on an ordinary
        // appeal it is false and the price is twenty dollars. The three states
        // and why they stay distinguishable are at
        // `ArbiterRegistryStorage.Data.appealPricedAtNought`. Widening what it
        // claims means widening where it is written, and that is the 22 100
        // again.
        //
        // ⚠️ AND THE CONDITION IS FALSE ON EVERY CALL SINCE 20 OCTOBER 2026.
        // The pot ceiling went back onto `caseBondFor` alone, so
        // `appealDepositFor` never answers below `APPEAL_DEPOSIT_FLOOR` and
        // this line writes nothing. It is kept, not deleted: it costs nothing
        // on a branch that is never taken, and it is the whole of what stands
        // between a future nought price and twenty dollars nobody put down.
        // What would revive it is listed at `_depositOf`.
        if (deposit == 0) d.appealPricedAtNought[agreement] = true;
        // ── THE LOT IS SET UP HERE, AND PULLED LATER (14 October 2026) ─────
        //
        // Two numbers and one cold SSTORE: they share a slot (see
        // `PendingVerdict.appealSeedBlock`). Nothing is drawn here, because
        // nothing CAN be — the hash of a block five ahead is zero for
        // everybody, including the man pressing this button, and that is
        // precisely why the height is written instead of the panel.
        //
        // ⚠️ WHY THE CORPS SIZE IS READ AT THIS DOOR, in a function whose own
        // comment four lines up says nothing is counted here any more. It is
        // ONE cold SLOAD of a length, not a walk: 2 100 gas, flat, where the
        // walk this branch deleted cost 150 029 at four seats and 2 546 205 at
        // five hundred. What the appellant is being charged for is no longer
        // "how many people might review this" but "which numbers the lot
        // divides by", and that number has to be fixed before the seed exists
        // or it becomes a six-dollar lever — see `appealCorps`.
        //
        // ⚠️ AND IT IS STILL THE LENGTH, GRAVES AND ALL, AFTER 14 OCTOBER 2026.
        // The roster no longer shrinks — a departing seat is zeroed — so this
        // number counts empty slots, and that is deliberate: it is the index
        // space the lot divides by, not a headcount. Writing a count of living
        // arbiters here would put every arbiter above that count out of reach
        // of every seed. The whole argument, and what the graves cost in
        // refused draws, is at `PendingVerdict.appealCorps`.
        v.appealSeedBlock = uint64(block.number + APPEAL_SEED_DELAY_BLOCKS);
        v.appealCorps     = uint64(d.arbiterList.length);
        // ── AND THE FILING ITSELF IS WRITTEN DOWN, IN BOTH UNITS
        //    (29 October 2026, decision 244) ──
        //
        // One cold SSTORE for a fresh slot and one warm overwrite inside it —
        // the appellant's money, and the two reasons are at
        // `PendingVerdict.appealFiledAt` and `.appealFiledAtBlock`. Short
        // version: both numbers used to be recovered by subtraction from a
        // field this work makes MOVABLE. The moment came out of
        // `appealDeadline - APPEAL_REVIEW_WINDOW`, and the deadline is
        // re-stamped when a panel is summoned on a re-thrown seed, so from that
        // moment on the subtraction answers with the SUMMONS and not with the
        // filing; the HEIGHT came out of
        // `appealSeedBlock - APPEAL_SEED_DELAY_BLOCKS`, and a throw of the lot
        // overwrites that field outright.
        //
        // ⚠️ THE SUBTRACTION IS EXACT AGAIN FOR EVERY APPEAL THAT NEVER
        // MOVES — the deadline is the filing plus four days once more — AND
        // THAT IS PRECISELY WHY THE STAMP IS NOT OPTIONAL. "Exact unless
        // somebody threw the lot" is not a rule anybody can read off a slot,
        // and the two readers (`_seatsOpenAt` and the draw's grave test) would
        // answer days or thousands of blocks out on the one appeal shape that
        // does move.
        //
        // ⚠️ BOTH ARE NON-ZERO FROM HERE ON, AND THE FIRST OF THEM IS THE ONE
        // MARKER for everything decision 244 added: an appeal carrying a zero
        // in it was filed before the field existed and is answered by the rules
        // it was filed under, everywhere those rules differ.
        ArbiterRegistryStorage.writeAppealFiling(d, agreement);
        // ⚠️ NO BAR IS FROZEN HERE ANY MORE, and the mapping that held it
        // (`appealVotesRequired`) keeps its slot unwritten — the layout is
        // append-only and a field is never taken back out. The bar stopped
        // depending on the corps when the panel stopped being drawn from it,
        // so there is nothing left to freeze: every appeal raised from today
        // needs the same three votes, and `_overturnVotesRequired` answers
        // that for a zero. One cold SSTORE saved on every appeal, which is the
        // appellant's money.

        // ⚠️ THE SEED HEIGHT IS READ OUT OF THE RECORD AND NOT RECOMPUTED HERE.
        // `block.number + APPEAL_SEED_DELAY_BLOCKS` is four lines up, and
        // writing the same arithmetic twice would let the log and the storage
        // disagree after an edit to one of them. One owner for the number: the
        // field.
        emit ArbiterRegistryFacet.AppealRaised(agreement, caller, v.appealSeedBlock);
    }

    // ⚠️ `_eligibleVoterCount` WAS DELETED HERE ON 23 SEPTEMBER 2026, together
    // with `_votesRequiredFor`, and this note stands in their place because
    // their absence is load-bearing. The first walked `arbiterList` to count
    // who could vote; the second turned that count into a quorum. Both were
    // called from `raiseAppeal`, so the corps' size was priced into every
    // appeal — see the measurement quoted there. Nothing in this file may walk
    // that list on a user's path again: the list has no ceiling, and the man
    // paying is the one challenging a verdict.
    //
    // ⚠️ ONE WALK DOES REMAIN IN THIS FILE, AND IT IS NAMED HERE RATHER THAN
    // LEFT TO BE FOUND. `resignAsArbiter` walks the roster to find the caller's
    // own slot. It is on a user's path — the arbiter leaving — and since 14
    // October 2026 the roster never shortens, so that walk only gets dearer.
    // The difference from the walk deleted above is WHO PAYS: the man leaving
    // pays for his own exit, and no appellant is charged for the size of the
    // corps entitled to review him. Buying it out with a stored index is
    // written up at `resignAsArbiter` and is not free either — every arbiter
    // already on the chain would read index zero, so the loop would have to
    // stay as a fallback or a backfill would have to run first.
    //
    // What replaced them is the seat count itself. The panel has
    // APPEAL_PANEL_SEATS seats, a vote IS the seat, and `voteToOverturn`
    // refuses the arbiter who arrives when they are gone. Who may sit is asked
    // of the ONE man pressing the button, never of the roster.

    /// When this appeal's seats open: an hour after it was raised.
    ///
    /// ⚠️ THE MOMENT IT WAS RAISED IS STORED FROM 29 OCTOBER 2026, AND THE
    /// PARAGRAPH THAT STOOD HERE SAID IT NEVER WOULD BE. It is quoted rather
    /// than deleted, because it is the measurement that made the field
    /// necessary and it was right on its own terms:
    ///
    ///   "`appealDeadline` is the only mark `raiseAppeal` leaves on the clock,
    ///   so the raise is read back out of it. A field of its own would be
    ///   honest arithmetic bought with one cold SSTORE on every appeal... It is
    ///   left live because the damage is bounded and small: the window can only
    ///   be changed by a cut, AN APPEAL LIVES FOUR DAYS, and the worst case is
    ///   an arbiter waiting that much longer or that much less for a seat."
    ///
    /// ⚠️ AND THE PARAGRAPH THAT REPLACED IT IS ITSELF CANCELLED AS OF THE
    /// EVENING OF 29 OCTOBER 2026 — KEPT MARKED AND NOT STRUCK OUT, by the
    /// house rule of 4 September 2026 that a cancelled note is dated rather
    /// than erased. It read:
    ///
    ///   "THE BOUND WAS THE SENTENCE 'AN APPEAL LIVES FOUR DAYS', AND DECISION
    ///   244 MAKES IT SEVEN. `appealDeadline` is now the filing plus
    ///   `APPEAL_TOTAL_WINDOW`, so `deadline - APPEAL_REVIEW_WINDOW` answers
    ///   with a moment THREE DAYS after the real filing, and the seats of every
    ///   appeal standing at the cut would open three days late — on a four-day
    ///   appeal, never."
    ///
    /// An appeal lives four days again, so that three-day error does not exist
    /// and the zero branch below is EXACT once more. WHAT THE STORED MOMENT IS
    /// FOR INSTEAD: the deadline is re-stamped when a panel is summoned on a
    /// re-thrown seed, and after that re-stamp
    /// `deadline - APPEAL_REVIEW_WINDOW` is the SUMMONS and not the filing — so
    /// a stretched appeal would read as opening its seats hours or days after
    /// it really did, and an arbiter would be refused a seat that was open.
    /// Same class, third time in this file (`RemovalProposal.ttl`,
    /// `appealDeposit`), and paid off the same way: the number is frozen in the
    /// record, and the record's zero means the rule that record was written
    /// under.
    ///
    /// ⚠️ THE ZERO BRANCH IS THE OLD ARITHMETIC, CHARACTER FOR CHARACTER, and
    /// it must stay that way: an appeal filed before the field existed was
    /// filed when `appealDeadline` was the filing plus four days, it can never
    /// be thrown again (`_lotThrow` answers `NotOffered` for it) and so its
    /// deadline can never be re-stamped. The subtraction is exact for it, and
    /// for nothing else that needs it.
    ///
    /// Only ever called where `v.appealed` is already true, so `appealDeadline`
    /// is non-zero; the guard below is for the view, which answers for verdicts
    /// that carry no appeal at all.
    function _seatsOpenAt(
        ArbiterRegistryStorage.Data storage d,
        address agreement,
        ArbiterRegistryStorage.PendingVerdict storage v
    )
        private
        view
        returns (uint256)
    {
        uint256 filedAt = ArbiterRegistryStorage.appealFiledAt(d, agreement);
        if (filedAt != 0) return filedAt + APPEAL_SEAT_DELAY;
        uint256 deadline = v.appealDeadline;
        if (deadline < APPEAL_REVIEW_WINDOW) return APPEAL_SEAT_DELAY;
        return deadline - APPEAL_REVIEW_WINDOW + APPEAL_SEAT_DELAY;
    }

    /// What this appeal's right to throw the lot again is in, right now.
    ///
    /// FOUR STATES AND NOT A BOOLEAN, because three of them are refusals that
    /// mean different things to the man reading them: "this appeal never had
    /// the right", "the summons door is shut", "you have had your throw". A
    /// boolean
    /// would make the summons door invent the reason a second time.
    ///
    /// ⚠️ NOT STORED ANYWHERE AND NOT PART OF ANY LAYOUT — it is a return type
    /// of one private function, so no slot, no selector, nothing to migrate.
    enum LotThrow { NotOffered, Open, Spent, WindowOver }

    /// ── IS THERE A THROW OF THE LOT LEFT IN THIS APPEAL?
    ///    (29 October 2026, decision 244) ──
    ///
    /// ONE FUNCTION AND NOT TWO CONDITIONS, because two doors need the same
    /// rule and need different things from it: `summonAppealPanel` has to say
    /// WHICH refusal applies, and `resolveAppeal` only has to know whether a
    /// throw is still possible at all. Written out in both places they would
    /// agree until the first edit to either, and the day they parted an appeal
    /// would be both settleable as dead and still throwable — the coupling the
    /// forfeit of decision 179 was deleted for.
    ///
    /// ⚠️ THE ORDER OF THE THREE TESTS IS THE RULE AND NOT A STYLE. The
    /// window is asked BEFORE the count, because an unused throw expires with
    /// the window rather than outliving it; and `NotOffered` is asked before
    /// both, because an appeal filed before the field existed never had a throw
    /// to lose.
    ///
    /// ⚠️ AND THE WINDOW IT ASKS ABOUT IS THE SUMMONS DOOR AND NOT THE
    /// DEADLINE (29 October 2026, evening, decision 244 as corrected). The
    /// deadline is four days and it MOVES; the door is the third day and it
    /// does not move for any reason whatever. Two things turn on that being the
    /// door: a throw made after the door shut would buy a panel that can never
    /// be summoned, and the refusal has to arrive AT THE THROW rather than a
    /// day later at the pull; and a throw nobody spent has to stop holding the
    /// settlement door the moment it has become worthless, or the other side's
    /// escrow stays frozen for a day after the last useful throw — which is
    /// exactly the cost the correction of that evening was made to stop
    /// charging him.
    function _lotThrow(
        ArbiterRegistryStorage.Data storage d,
        address agreement,
        ArbiterRegistryStorage.PendingVerdict storage v
    )
        private
        view
        returns (LotThrow)
    {
        if (ArbiterRegistryStorage.appealFiledAt(d, agreement) == 0) return LotThrow.NotOffered;
        // ⚠️ AND NO SEED HEIGHT IS NO THROW EITHER, WHICH IS THIS FUNCTION
        // AGREEING WITH THE DOOR IT SERVES. `summonAppealPanel` refuses an
        // appeal carrying no height with `AppealHasNoSeedHeight` before it ever
        // asks this question, so a throw on such an appeal is a right nobody
        // can exercise — and `resolveAppeal` reads this same function to decide
        // whether anything is still worth waiting for. Without this line the
        // settlement of an appeal that CAN NEVER HAVE A PANEL would be held for
        // three days by a throw that cannot be spent, which is the same cost
        // the owner struck out on the evening of 29 October 2026: somebody
        // else's escrow frozen for a repair that cannot help anybody.
        //
        // Two definitions of one word is the defect this file keeps naming; the
        // door's definition is the one that governs, and this is it.
        if (v.appealSeedBlock == 0) return LotThrow.NotOffered;
        if (block.timestamp > _summonsClosesAt(d, agreement, v)) return LotThrow.WindowOver;
        if (ArbiterRegistryStorage.appealThrowsSpent(d, agreement) >= APPEAL_MAX_RE_ROLLS) {
            return LotThrow.Spent;
        }
        return LotThrow.Open;
    }

    /// The last moment at which a panel may be summoned to this appeal.
    ///
    /// ⚠️ THE FIVE ARE GUARANTEED `APPEAL_REVIEW_WINDOW`, AND IT IS RESERVED
    /// AT THE END OF THE WEEK. Decision 244's repair opens a road that did not
    /// exist before it: the seed used to live 51 seconds, so a panel was
    /// summoned in the first minute or never, and "a panel with no time to
    /// answer" was not a reachable state. With the lot throwable for days the
    /// appellant could summon five men on the sixth day, give them one day
    /// instead of four, and lose the whole price to the TREASURY when they
    /// did not answer — the cliff MOVED rather than removed, and dressed as
    /// hope.
    ///
    /// ⚠️ THIS SENTENCE READ "to the other side" WHEN IT WAS WRITTEN ON
    /// 29 OCTOBER 2026. The addressee of that road moved to the treasury on
    /// 19 October 2026, and the retired wording is decision 200's table row —
    /// a snapshot of that day taken before its evening correction. What the
    /// appellant LOSES is the same number either way, which is why the cliff
    /// is the point of this paragraph and the addressee is not.
    ///
    /// ⚠️ IT IS DERIVED FROM THE FILING STAMP AND NO LONGER FROM THE
    /// DEADLINE, AND THAT CHANGED ON THE EVENING OF 29 OCTOBER 2026 WITHOUT THE
    /// DOOR MOVING BY A SECOND. It used to be
    /// `appealDeadline - APPEAL_REVIEW_WINDOW`, which was honest while the
    /// deadline was the filing plus a week and frozen for good: the filing plus
    /// seven days less four is the filing plus three. The deadline is the
    /// filing plus FOUR days now, and it is re-stamped when a panel is summoned
    /// on a re-thrown seed — so read off the deadline this door would be the
    /// filing moment itself on an ordinary appeal, refusing the very first
    /// pull, and it would MOVE OUTWARD every time it was pushed, the re-stamp
    /// buying a fresh summons window, which is the one thing the ceiling exists
    /// to forbid. Read off the filing it is the filing plus three days for
    /// every appeal and at every hour of its life. Decision 244's point 9 to
    /// the second: the number of this door does not change.
    ///
    /// ⚠️ WHAT ABSORBS A CUT TO EITHER CONSTANT IS STILL THE SUMMONS WINDOW,
    /// which is the direction this function was built in and why it is a span
    /// taken out of the ceiling rather than a stamp of its own. The five always
    /// get the window in force; what shrinks or grows is the span in which the
    /// appellant may go looking for them, and that belongs to him rather than
    /// to the men who have to read the case.
    ///
    /// ⚠️ THE ZERO BRANCH IS THE RECORD'S OWN DEADLINE, AND GETTING IT WRONG
    /// WOULD KILL LIVE APPEALS ON THE CHAIN. An appeal filed before the mark
    /// existed carries no filing stamp; it was filed under "the deadline is the
    /// filing plus four days"; it has no throw at all (`_lotThrow` answers
    /// `NotOffered` for it); and it lived under no summons door whatever — its
    /// only limit was the seed's 256-block horizon. Its own deadline is
    /// therefore the honest last moment for it, and it is the one this branch
    /// returns. The live branch's arithmetic must NOT be reached for it: with
    /// no stamp to add to, "the deadline less the review window" is the filing
    /// moment itself, and the door would refuse even its first lawful pull.
    ///
    /// ⚠️ NO UNDERFLOW GUARD IS NEEDED ANY MORE AND THE TERNARY THAT STOOD
    /// HERE WENT WITH THE SUBTRACTION IT GUARDED. The two constants are folded
    /// by the compiler, so the live branch is an addition to a timestamp and
    /// nothing is taken away from anything; the zero branch returns a stored
    /// stamp as it stands. Neither can `Panic(0x11)` — the nameless failure
    /// this file keeps buying its way out of (`getOpenJobs()`, July 2026).
    function _summonsClosesAt(
        ArbiterRegistryStorage.Data storage d,
        address agreement,
        ArbiterRegistryStorage.PendingVerdict storage v
    )
        private
        view
        returns (uint256)
    {
        uint256 filedAt = ArbiterRegistryStorage.appealFiledAt(d, agreement);
        if (filedAt == 0) return v.appealDeadline;
        return filedAt + (APPEAL_TOTAL_WINDOW - APPEAL_REVIEW_WINDOW);
    }

    /// How many votes to overturn THIS verdict: APPEAL_OVERTURN_VOTES, three.
    ///
    /// ⚠️ A STORED VALUE STILL WINS, AND THE MAPPING IS NOT DEAD WEIGHT.
    /// Between 18 and 23 September 2026 `raiseAppeal` froze `min(CAP,
    /// eligible)` into it, so an appeal raised in that window carries the bar
    /// it was paid for and is held to that and not to today's rule. Nothing
    /// writes the mapping from 23 September on; this is its only reader.
    ///
    /// ⚠️ WHY A STORED TWO IS STILL HONOURED AFTER 177 RAISED THE BAR TO
    /// THREE, and why that is not the retroactivity this file keeps guarding
    /// against. What a stored bar bought was never "two presses of a button":
    /// under the old two-direction rule an appeal at a bar of two needed BOTH
    /// votes to say overturn, because a one-against-one tie upheld. Two votes
    /// to overturn is exactly what it means today. At a stored three the new
    /// rule asks for three overturns where the old asked two of three, which is
    /// stricter — never looser than what that appellant paid for. Measured on
    /// the live diamond on 14 October 2026 before this cut: `getDisputed()`
    /// answered an empty list, so no verdict was under appeal and this window
    /// holds nobody.
    function _overturnVotesRequired(
        ArbiterRegistryStorage.Data storage d,
        address agreement
    ) private view returns (uint256) {
        uint256 stored = d.appealVotesRequired[agreement];
        return stored == 0 ? APPEAL_OVERTURN_VOTES : stored;
    }

    /// ── THE SEED THIS DRAW WILL USE, OR THE LOT THROWN AGAIN INSTEAD ───────
    ///
    /// Everything `summonAppealPanel` has to settle BEFORE it may look at a
    /// block hash: the appeal's own two clocks, the seed's three, and — when
    /// the seed has gone stale — whether this caller may throw the lot again
    /// (29 October 2026, decision 244).
    ///
    /// @return seedBlock the height to draw from; nought when the lot was
    ///                   thrown instead of drawn
    /// @return thrown    true when this call SPENT A THROW and wrote a new
    ///                   height, so the caller must return and draw nothing
    ///
    /// ⚠️ A FUNCTION AND NOT A PARAGRAPH INSIDE THE DRAW, AND THE REASON IS
    /// THE COMPILER RATHER THAN TASTE. Written inline, the five locals this
    /// needs (`thrw`, the window's last moment, the horizon's last block, the
    /// throws spent, the appellant) sit in the same frame as the draw's two
    /// fixed arrays and its three loop variables, and `via_ir` answered with
    /// `Variable memPtr_93 is 1 too deep in the stack` — not in this file, but
    /// in a test file compiled in the same unit, because the inliner's budget
    /// is global. MEASURED, not guessed: the committed tree compiled the same
    /// twenty appeal suites and ran 241 tests green; with this block inline and
    /// nothing else changed, the unit refused to compile at all.
    ///
    /// ⚠️ SO THE SPLIT IS LOAD-BEARING AND NOT COSMETIC: folding it back is not
    /// a tidy-up, it is a build failure three files away from the edit.
    ///
    /// `private` and not `view`: the throw-again branch WRITES.
    function _seedOrThrowAgain(
        ArbiterRegistryStorage.Data storage d,
        address agreement,
        ArbiterRegistryStorage.PendingVerdict storage v
    )
        private
        returns (uint256 seedBlock, bool thrown)
    {
        seedBlock = v.appealSeedBlock;
        if (seedBlock == 0) revert ArbiterRegistryFacet.AppealHasNoSeedHeight();

        // ── THE TWO CLOCKS OF THE APPEAL, ASKED BEFORE THE CLOCK OF THE SEED
        //    (29 October 2026, decision 244) ──
        //
        // ⚠️ BOTH ARE ABOVE THE SEED TESTS DELIBERATELY, AND THE ORDER IS THE
        // RULE. A seed is good for 256 blocks from the height it names, so a
        // throw of the lot in the last seconds of the summons window would hand
        // the panel a live seed PAST that window, and a pull on the fourth day
        // would carry five men into a case they cannot finish reading inside
        // the ceiling. "The door is shut" has to be the outermost question or
        // it shuts nothing.
        //
        // ⚠️ AND EACH REFUSES BY ITS OWN NAME, never by the seed's. A man told
        // `AppealSeedExpired` has been told to give up on a seed; a man told
        // `AppealSummonsWindowClosed` has been told he is too late to call a
        // panel, which is decision 244's point 9 — and the throw of the lot
        // past that same border refuses by that same name, because `_lotThrow`
        // reads the same border; a man told `AppealOver` has been told the case
        // itself is finished. Three sentences, and the screen says three
        // different things.
        LotThrow thrw = _lotThrow(d, agreement, v);
        // THE APPEAL ITSELF, FIRST, AND IT IS THE ONLY DEADLINE READ ON THIS
        // PATH. Unreachable through this door for any appeal that carries a
        // filing stamp — the summons window closes `APPEAL_REVIEW_WINDOW`
        // before the ceiling and the deadline is never earlier than that, so
        // the test below always answers first — and NOT dead code, for the
        // reason the two ternaries in this file are not: it is the named,
        // fail-closed answer for a record whose two stamps disagree, and it is
        // the live answer for an appeal filed before the mark existed, whose
        // door IS its own deadline.
        if (block.timestamp >= v.appealDeadline) revert ArbiterRegistryFacet.AppealOver(v.appealDeadline);
        // The five are guaranteed their reading time and it is reserved at the
        // end of the week — see `_summonsClosesAt`. ASKED OF EVERY APPEAL,
        // including one filed before the mark existed: for that one the
        // function answers with its own deadline rather than with a
        // subtraction, so the door cannot be shut on an appeal that is lawfully
        // waiting for its panel. That is why the `NotOffered` guard that stood
        // here is gone rather than kept — the special case moved into the
        // function that owns the border, where one reader cannot forget it.
        uint256 lastMoment = _summonsClosesAt(d, agreement, v);
        if (block.timestamp > lastMoment) {
            revert ArbiterRegistryFacet.AppealSummonsWindowClosed(lastMoment);
        }

        // Three refusals and not one, because they mean three different things
        // to whoever is waiting: come back in seconds, come back never, and
        // something is wrong with this chain.
        if (block.number <= seedBlock) revert ArbiterRegistryFacet.AppealSeedNotReady(seedBlock);
        uint256 lastBlock = seedBlock + APPEAL_SEED_HORIZON_BLOCKS;
        if (block.number > lastBlock) {
            // ── THE SEED WENT STALE: THE APPELLANT MAY THROW THE LOT AGAIN
            //    (29 October 2026, decision 244) ──
            //
            // This is the whole repair, and the sentence it replaces was
            // `revert AppealSeedExpired(lastBlock)` — "come back never".
            // What made that answer wrong is not the lot but the CHAIN: the
            // 256-block horizon was about nine minutes at a two-second block
            // and is 51 seconds at the 0.2-second block Base Sepolia has run
            // since 21 October 2026, and in 51 seconds a man who has just been
            // notified cannot open a page, connect a wallet and confirm. Miss
            // it and decision 200's "nobody answered" branch spends the WHOLE
            // appeal price: it goes to the TREASURY and comes back to nobody,
            // and what the other side of the deal gets for having done
            // nothing at all is his escrow unfrozen, not the money.
            //
            // ⚠️ IT READ "hands the WHOLE appeal price to the other side of
            // the deal — who had to do nothing at all to earn it" WHEN IT WAS
            // WRITTEN ON 29 OCTOBER 2026. That was the rule of 17 October,
            // retired by the owner on the 19th, and it was copied here out of
            // decision 200's table row — a snapshot of the 19th taken before
            // that evening's correction. The loss to the appellant, which is
            // what this paragraph is about, is unchanged.
            //
            // ⚠️ THE OLD REFUSAL IS STILL THE ANSWER FOR AN APPEAL FILED
            // BEFORE THE FIELD EXISTED, and reading its zero the other way
            // round would have been the one unforgivable version of this
            // change: every appeal in flight would gain a right it was not
            // filed with, and — worse — the settlement door would stop being
            // pressable for it, freezing somebody else's escrow on a rule
            // nobody agreed to.
            if (thrw == LotThrow.NotOffered) {
                revert ArbiterRegistryFacet.AppealSeedExpired(lastBlock);
            }
            // ⚠️ THE COUNT IS ASKED BEFORE THE SENDER, and that is for the
            // benefit of whoever is reading the refusal. With the throws spent,
            // the answer is the same for the appellant and for a stranger —
            // "there are none left" — and telling the stranger "only the
            // appellant may" would be true and useless.
            uint256 spent = ArbiterRegistryStorage.appealThrowsSpent(d, agreement);
            if (thrw == LotThrow.Spent) revert ArbiterRegistryFacet.AppealReRollsSpent(spent);

            // ⚠️ THE ONE PLACE IN THIS FUNCTION THAT READS A SENDER, AND IT
            // READS IT THROUGH `_msgSender()`. The ordinary pull above is
            // deliberately senderless — a stranger's pull produces the same
            // five — but a CHOICE between panels is the appellant's and nobody
            // else's (decision 244). `msg.sender` here would be the
            // forwarder's address on every gasless call and the appellant
            // would be refused on his own appeal: the exact shape of the
            // `fundDispute` bug of 31 July 2026 (fixed in d172064).
            address appellant = v.appellant;
            if (_msgSender() != appellant) {
                revert ArbiterRegistryFacet.AppealReRollNotAppellant(appellant);
            }

            // A height and not a value, for the same reason `raiseAppeal`
            // writes a height: the hash of a block five ahead is zero for
            // everybody, including the man pressing this button, so he cannot
            // pick the panel he is about to be given.
            //
            // ⚠️ `appealCorps` IS NOT RE-FROZEN, AND MUST NOT BE. It was fixed
            // before the first seed existed, which is what keeps it from being
            // a six-dollar lever on the index space; re-reading the roster here
            // would let a man who can already compute the five buy a new N to
            // divide by. The corps the appellant appealed to does not change
            // because his first lot went stale.
            //
            // ⚠️ AND `appealFiledAtBlock` IS NOT TOUCHED EITHER. The draw reads
            // it to decide which seats were graves at the FILING; moving it
            // here would hand back the substitution lever decision 185 closed.
            v.appealSeedBlock = uint64(block.number + APPEAL_SEED_DELAY_BLOCKS);
            ArbiterRegistryStorage.countAppealThrow(d, agreement, spent);
            return (0, true);
        }
        return (seedBlock, false);
    }

    /// @notice Pulls the lot: the chain summons this appeal's panel. Five
    /// arbiters (fewer if the corps is smaller) are taken by number out of the
    /// corps as it stood when the appeal was raised, written down, and from
    /// then on they are the only people who may vote on it.
    ///
    /// Anybody may send this transaction and it costs the sender nothing but
    /// gas, because WHO sends it cannot change the answer. Both inputs were
    /// fixed before this transaction could be thought of: the height the seed
    /// comes from, and the corps size the numbers are taken modulo. That is
    /// 177's requirement in full — neither the appellant, nor whoever pulls
    /// the lot, nor an arbiter can choose the five or know them early enough
    /// to buy them.
    ///
    /// ── WHY THERE ARE TWO TRANSACTIONS AND NOT ONE ─────────────────────────
    ///
    /// The seed cannot be read in the transaction that fixes it: a block's
    /// hash is unknowable while the block is being built, which is the only
    /// reason it is worth anything here. So `raiseAppeal` fixes a height and
    /// this door reads it, APPEAL_SEED_DELAY_BLOCKS later. The step is meant
    /// to be invisible to the appellant — his own browser sends it about ten
    /// seconds after the raise — and it is permissionless so that a browser
    /// that was closed, or a relayer that was down, costs nobody his appeal:
    /// an arbiter, the winning party, or a passer-by can pull it instead.
    ///
    /// ⚠️ AND IF NOBODY PULLS IT, which is a real outcome and not a theory:
    /// the seed goes stale — 51 seconds at the chain's present speed, not the
    /// eight and a half minutes this paragraph used to quote — and the panel
    /// never assembles.
    ///
    /// ⚠️ FROM 29 OCTOBER 2026 (decision 244) THAT IS NO LONGER THE END OF THE
    /// APPEAL, AND THIS PARAGRAPH SAID IT WAS: "deliberately NOT a re-draw".
    /// It is a re-draw now, ONCE, and only for the appellant, inside the
    /// one absolute deadline frozen when he filed. What changed the answer is
    /// not the lot but the chain — see the branch below the horizon test — and
    /// what has NOT changed is where the money goes when five men were summoned
    /// and none of them answered: decision 200, untouched.
    ///
    /// ── HOW THE FIVE ARE TAKEN ─────────────────────────────────────────────
    ///
    /// Floyd's F2 selection sampling: exactly `seats` iterations, each one
    /// keccak and at most `seats - 1` comparisons against the numbers already
    /// held — ten comparisons for five seats, and not one read of the roster
    /// beyond the five slots the numbers point at. The cost is therefore FLAT
    /// in the corps size, which is the property this file paid 2 546 205 gas
    /// to learn the value of: the walk it replaced charged the appellant for
    /// the size of the corps entitled to review him. Measured at 4, 100 and
    /// 500 arbiters in test/AppealPanelGas.t.sol.
    ///
    /// Why F2 rather than rejection sampling with retries: retries are a loop
    /// whose length depends on luck, and at a corps of six a clean pass of
    /// five distinct numbers happens about nine times in a hundred — so a
    /// bounded retry budget would quietly drop seats exactly where the corps
    /// is smallest. F2 needs no retries at all: a number already held is
    /// replaced by the step's own upper bound, which cannot be held yet.
    ///
    /// ⚠️ THE MODULO IS BIASED, and by how much: a 256-bit value reduced modulo
    /// at most a few hundred leaves a bias of order 2^-250. It is named here so
    /// that nobody has to wonder whether it was thought about.
    ///
    /// ── WHAT A LOST SEAT IS ────────────────────────────────────────────────
    ///
    /// A number may point at nobody: the corps size is frozen at the raise, and
    /// an index can land on the slot of a man who has since left. Such a seat
    /// is skipped and the panel is shorter — visibly, through `appealSummoned`
    /// and `getAppealSummons`, never by pretending five were called. The same
    /// shortfall is what absorbs a summoned arbiter who turns out to be
    /// suspended, a party, or the ruling arbiter himself: the lot does not ask
    /// those three (see APPEAL_PANEL_SEATS), those men are refused at the
    /// voting door, and the redundancy of five over a bar of three pays for it.
    ///
    /// ⚠️ AND A SEAT WITH NO FRANCHISE IS A LOST SEAT TOO, SINCE 16 OCTOBER
    /// 2026 (decision 187) — the one admission question the draw does ask, and
    /// it asks it through `_mayVoteOnAppeals`. Before that day the draw could
    /// write down a man who silently could not vote, so a panel that read as
    /// full held fewer usable votes than the bar wanted. The whole of it is at
    /// the third test in the loop below.
    ///
    /// ⚠️ A LOST SEAT IS NOW THE ONLY THING A DEPARTURE CAN DO, and that is the
    /// change of 14 October 2026. The roster used to be spliced by swap-and-pop
    /// in three files, so a man leaving between the seed's block and this
    /// transaction moved the LAST arbiter into his index — and the index the
    /// seed chose answered with somebody else. Seats are zeroed now and the
    /// array never shortens (`resignAsArbiter` carries the argument), so a
    /// departure SUBTRACTS from the panel and cannot SUBSTITUTE into it.
    /// Measured in test/AppealLotSeatIsAGrave.t.sol.
    ///
    /// ⚠️ AND A GRAVE IS FILLABLE FROM 16 OCTOBER 2026 (decision 185), WHICH
    /// DOES NOT CHANGE THE SENTENCE ABOVE. A seat refilled at or after the
    /// height this appeal was filed at reads as a grave here, by its stamped
    /// height — so a departure plus a reseating still only SUBTRACTS from this
    /// panel, and the man who sat down is reachable by appeals filed after him
    /// and by nothing earlier. Without that test the refilling would be the old
    /// lever back and cheaper; the whole of it is at the comparison inside the
    /// loop below.
    ///
    /// If too few seats resolve for the bar to be reachable at all, the draw is
    /// refused by name rather than written down: an appeal whose panel cannot
    /// arithmetically overturn anything must end in "no panel assembled", not
    /// hang waiting for votes that cannot come.
    function summonAppealPanel(address agreement) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        // No sender is read on the path that DRAWS, deliberately: the same call
        // from the appellant's browser, from a relayer, or from a stranger
        // produces the same five, so there is nothing for a forwarder to get
        // wrong here. The one branch that does read a sender is the throw of
        // the lot again, in `_seedOrThrowAgain` above, and it says why.
        if (!v.appealed) revert ArbiterRegistryFacet.NoAppeal();
        if (v.appealResolved) revert ArbiterRegistryFacet.AppealAlreadyResolved();
        // Pressed twice, or pressed while somebody else's press is in the same
        // block: the second one is refused by name and changes nothing.
        if (v.appealSummoned != 0) revert ArbiterRegistryFacet.AppealPanelAlreadySummoned();

        (uint256 seedBlock, bool thrown) = _seedOrThrowAgain(d, agreement, v);
        // A throw spent: a new height is written, no panel is drawn, and the
        // appellant comes back when the delay has passed.
        if (thrown) return;

        bytes32 seed = blockhash(seedBlock);
        if (seed == bytes32(0)) revert ArbiterRegistryFacet.AppealSeedUnavailable();

        uint256 n = v.appealCorps;
        uint256 seats = n < APPEAL_PANEL_SEATS ? n : APPEAL_PANEL_SEATS;
        uint256 listLength = d.arbiterList.length;

        // ── THE HEIGHT THIS APPEAL WAS FILED AT (16 October 2026) ──────────
        //
        // Recovered from the seed height rather than stored: `raiseAppeal`
        // wrote `block.number + APPEAL_SEED_DELAY_BLOCKS` in the filing
        // transaction, so the two are the same number by construction. A
        // second field would be a second owner for one number, free to
        // disagree after an edit to one of them — the defect
        // `PendingVerdict.appealDeposit` was appended to fix, in a different
        // currency.
        //
        // ⚠️ THE TERNARY IS NOT A STYLE CHOICE AND NOT DEAD CODE EITHER.
        // Nothing `raiseAppeal` can write is below the delay (it writes
        // `block.number + 5`), and a seed height of zero is already refused
        // above by name — so the false branch is unreachable through every
        // door that exists. It is written anyway because the alternative on an
        // unreachable path is `Panic(0x11)`, an arithmetic underflow with no
        // name on it, and this protocol has already lost a live read to a
        // nameless panic once (`getOpenJobs()`, July 2026). What the false
        // branch does instead is fail CLOSED: a filing height of zero makes
        // every seat a grave, and the draw then refuses by name through
        // `AppealPanelCannotAssemble` below.
        //
        // ⚠️ AND FROM 29 OCTOBER 2026 THE SUBTRACTION IS THE FALLBACK AND NOT
        // THE ANSWER, because the premise above — "the two are the same number
        // by construction" — stopped holding the moment the lot became
        // throwable again. A throw OVERWRITES `appealSeedBlock`, so on a
        // second or third attempt the subtraction answers with the height of
        // the LAST THROW rather than the filing, and every seat taken between
        // the two would read as part of the corps the appellant appealed to.
        // That is decision 185's substitution lever handed back for the price
        // of one throw. The height is stored now; the subtraction stays for the
        // appeals that carry a zero, and for those it is still exact, because
        // not one of them can be thrown again at all.
        uint256 filedAt = ArbiterRegistryStorage.appealFiledAtBlock(d, agreement);
        if (filedAt == 0) {
            filedAt = seedBlock >= APPEAL_SEED_DELAY_BLOCKS
                ? seedBlock - APPEAL_SEED_DELAY_BLOCKS
                : 0;
        }

        address[APPEAL_PANEL_SEATS] memory seatHolders;
        uint256 filled;
        {
            uint256[APPEAL_PANEL_SEATS] memory drawn;
            for (uint256 s; s < seats; ++s) {
                // F2: the upper bound rises by one each step, and a number
                // already held is replaced by that bound — which cannot be
                // held, because every number held so far is below it.
                uint256 j = n - seats + s;
                uint256 r = uint256(keccak256(abi.encodePacked(seed, s))) % (j + 1);
                for (uint256 t; t < s; ++t) {
                    if (drawn[t] == r) { r = j; break; }
                }
                drawn[s] = r;
                // ⚠️ THESE TWO CHECKS SWAPPED ROLES ON 14 OCTOBER 2026, and
                // which one is load-bearing matters to whoever edits next.
                //
                // `r < listLength` WAS the load-bearing one: the roster could
                // shrink between the raise and this transaction, so an index
                // could point past its end. For every appeal raised AFTER this
                // facet is mounted it is now a BELT over an append-only array —
                // nothing in src/ pops `arbiterList` any more, so
                // `listLength >= appealCorps > r` holds and this branch cannot
                // be false. What makes it unreachable is a property and not an
                // opinion, and the property has its own lock:
                // test/AppealLotSeatIsAGrave.t.sol:test_TheRosterNeverGetsShorterThroughAnyOfTheThreeExits.
                //
                // ⚠️ IT IS NOT A BELT FOR AN APPEAL THAT PREDATES THE CUT, and
                // that is exactly why it is not deleted. An appeal raised while
                // the roster could still be spliced may carry an
                // `appealCorps` larger than today's length, and for that one
                // the comparison is the only thing between a lost seat and an
                // out-of-bounds Panic. Measured on Base Sepolia on 14 October
                // 2026, before this change went anywhere: `getDisputed()`
                // answered an empty list, so no verdict was pending and no such
                // appeal existed — but the code is not entitled to lean on a
                // reading taken the day before a cut.
                //
                // `who != address(0)` IS NOW THE LOAD-BEARING ONE. It was a
                // belt before — nothing put a zero in the roster — and it is
                // now the single line that keeps a GRAVE out of a panel.
                // Without it `appealPanelSeats` would hold `address(0)` as a
                // summoned member, `appealSummoned` would count it, and the bar
                // of three could be met by seats nobody can ever vote from.
                // Its lock is
                // test/AppealLotSeatIsAGrave.t.sol:test_ADrawnGraveIsALostSeatAndNeverAZeroOnThePanel.
                //
                // ── AND A THIRD TEST SINCE 16 OCTOBER 2026 (decision 185) ──
                //
                // ⚠️ `seatTakenAtBlock[r] < filedAt` IS THE ONE THAT KEEPS THE
                // GRAVES FILLABLE WITHOUT GIVING THE SUBSTITUTION LEVER BACK,
                // and it is load-bearing from the moment the first grave is
                // refilled. Graves used to be permanent, so an index meant one
                // man for as long as the chain lived and this comparison would
                // have been a belt. They are fillable now — `vacantSeats`,
                // decision 185 — and that reopens the lever AT A LOWER PRICE
                // than swap-and-pop charged: the attacker sitting at index 3
                // watches the seed's block get mined, works out that the lot
                // chose 3, resigns, and seats his second address into the grave
                // he just made. No last man in the roster has to cooperate and
                // no removal has to ripen; he needs one spare address. The
                // index the seed chose would then answer with a man the frozen
                // `appealCorps` provably could not reach.
                //
                // What this line says instead: a seat whose holder took it AT
                // OR AFTER the height the appeal was filed at is a grave FOR
                // THIS APPEAL. He was not in the corps the appellant appealed
                // to — the same honest cut `appealCorps` already makes for a
                // man appended after the filing, now made for a man who sat
                // down in a grave as well.
                //
                // ⚠️ AT OR AFTER, NOT MERELY AFTER. The attack needs the seed,
                // and the seed does not exist until five blocks past the
                // filing, so `>` would close every seed-informed substitution
                // on its own. The filing block itself is included because a
                // seat taken in it may have been taken in a transaction ORDERED
                // AFTER the filing — the chain cannot tell the two apart later,
                // and the cheap side of an ambiguity about who was in the corps
                // is to leave him out of one appeal.
                //
                // ⚠️ ZERO PASSES, AND THAT IS THE POINT, not an oversight: a
                // seat whose height was never written is one taken before the
                // field existed, so it is older than every appeal that can be
                // filed from this cut on. See `seatTakenAtBlock`.
                //
                // ⚠️ IT COSTS ONE COLD SLOAD PER SEAT THAT RESOLVES — 2 100
                // gas, at most five of them — and a drawn grave pays nothing,
                // because `&&` short-circuits on the zero address above. The
                // draw stays flat in the corps size, which is the property this
                // function exists to have.
                //
                // Its lock is
                // test/AppealLotSeatIsAGrave.t.sol:test_AManSeatedIntoAGraveAfterTheFilingIsNotOnThisPanel,
                // and its positive control — a refilled grave IS reachable by
                // an appeal filed later, otherwise filling them buys nothing —
                // is test_AManSeatedIntoAGraveBeforeTheFilingIsSummonedByTheLot.
                //
                // ── AND A FOURTH TEST SINCE 16 OCTOBER 2026 (decision 187) ──
                //
                // ⚠️ `_mayVoteOnAppeals(d, who)` IS THE DRAW ASKING THE VOTING
                // DOOR'S OWN QUESTION, and until this line it did not ask it at
                // all. The two tests above are "somebody is in this slot" and
                // "he was in it before the filing"; neither of them is the
                // FRANCHISE, and `voteToOverturn` has a third refusal the lot
                // knew nothing about — `NoAdjudicatedCase`.
                //
                // So the lot could write down a man who SILENTLY CANNOT VOTE:
                // self-seated through `applyAsArbiter`, which leaves `seatedBy`
                // zero, and with no case of his own carried to a verdict that
                // stood. His seat was real, `appealSummoned` counted it, and
                // the bar of three was then being asked of a panel holding
                // fewer than three usable votes. Nothing named the reason; the
                // appellant had already paid his deposit and found out when the
                // window expired on a panel that never moved. The worst shape
                // is a corps where self-seated arbiters outnumber the
                // enfranchised — every panel drawn reads full and no appeal in
                // the protocol can be overturned by anybody.
                //
                // ⚠️ THROUGH THE SAME HELPER THE DOOR READS, AND NEVER A COPY
                // OF ITS CONDITION. Two definitions of one word agree until the
                // first edit to either, and the day they part there is no
                // answer to "which one is the franchise": the chain would call
                // a man one of them entitles and the other refuses, and the
                // panel would be short again with nothing named. `_mayVoteOnAppeals`
                // is `private` and this is its second caller.
                //
                // ⚠️ IT IS NOT A DEFENCE AGAINST CAPTURE AND MUST NOT BE READ
                // AS ONE. It makes the denominator honest, not smaller: the
                // share a circle has to buy is now a share of the ENFRANCHISED
                // seats rather than of all of them, and an enfranchised seat
                // costs more than a seat — a voucher from somebody who answers
                // for the choice, or one case carried to a verdict that stood.
                // The premium is about a tenth of what a seat costs, which is
                // small, and that is said here rather than left to sound like a
                // defence. Priced in decision 187.
                //
                // ⚠️ WHAT IT COSTS AND WHO PAYS. One cold SLOAD
                // (`seatedBy[who]`) per seat that gets this far, and a second
                // (`cleanVerdicts[who]`) only where the first is zero. It is
                // LAST of the three on purpose: a drawn grave still pays
                // nothing for it, and a seat refilled after the filing pays
                // nothing beyond its own height read. The bill lands on
                // whoever pulls the lot, which is the appellant's browser in
                // the ordinary case — re-measured, with the ceiling re-signed,
                // in test/AppealPanelGas.t.sol.
                //
                // Its lock is
                // test/AppealLotDrawsTheEnfranchised.t.sol:test_ASeatThatCannotVoteIsNotSummonedByTheLot,
                // and its positive control — an enfranchised seat IS still
                // called and the panel does assemble, without which a condition
                // that refuses everybody looks exactly like a working one — is
                // test_AnEnfranchisedSeatIsStillSummonedAndThePanelAssembles.
                if (r < listLength) {
                    address who = d.arbiterList[r];
                    if (
                        who != address(0)
                        && d.seatTakenAtBlock[r] < filedAt
                        && _mayVoteOnAppeals(d, who)
                    ) {
                        seatHolders[filled] = who;
                        ++filled;
                    }
                }
            }
        }

        // Read through the same helper every other door reads it through, so
        // the handful of appeals carrying a bar frozen in September are held to
        // their own number here too.
        uint256 needed = _overturnVotesRequired(d, agreement);
        if (filled < needed) revert ArbiterRegistryFacet.AppealPanelCannotAssemble(filled, needed);

        // Written only now, after the refusal above: a draw that cannot carry
        // an overturn pays for nothing.
        address[] memory called = new address[](filled);
        for (uint256 s; s < filled; ++s) {
            d.appealPanelSeats[agreement][s] = seatHolders[s];
            called[s] = seatHolders[s];
        }
        v.appealSummoned = uint64(filled);
        // ── AND FIVE MEN CALLED ON A SECOND SEED GET THEIR OWN FOUR DAYS
        //    (29 October 2026, evening, decision 244 as the owner corrected it
        //    that same day) ──
        //
        // THE SECOND AND LAST WRITE OF `appealDeadline` ANYWHERE IN THE
        // PROTOCOL, and it happens on one branch only: a panel summoned on a
        // RE-THROWN seed. `appealThrowsSpent` is non-zero exactly there,
        // because a throw of the lot is the only thing that writes it and the
        // seed that throw wrote is the seed this draw has just used.
        //
        // ⚠️ THE CONDITION IS THE RULE AND NOT AN OPTIMISATION. Re-stamped on
        // EVERY summons, an ordinary appeal — lot pulled in the first minute,
        // relayer alive, nothing whatever wrong — would end up carrying "the
        // filing plus four days plus however many seconds the pull took", and
        // the other side's escrow would be held those seconds longer in every
        // single case. It is the week's mistake again in a smaller unit: the
        // money tests of this tree are written to the second against the filing
        // plus four days, and they would go red on the seconds exactly as they
        // went red on the three days. On the ordinary path this writes nothing
        // at all — not a slot, not a bit.
        //
        // ⚠️ IT CANNOT SHORTEN ANYBODY'S DEADLINE, and that is arithmetic and
        // not care: a throw can only have been spent after the first seed's
        // horizon passed, so `now` is strictly later than the filing, so
        // `now + APPEAL_REVIEW_WINDOW` is strictly later than the
        // `filing + APPEAL_REVIEW_WINDOW` already in the slot. The clamp below
        // is a ceiling and never a floor.
        //
        // ⚠️ AND THE CLAMP IS WRITTEN AS A RULE THOUGH THE DOOR ALREADY
        // GUARANTEES IT. `_summonsClosesAt` refuses a summons after
        // `filing + APPEAL_TOTAL_WINDOW - APPEAL_REVIEW_WINDOW`, so
        // `now + APPEAL_REVIEW_WINDOW` cannot pass `filing +
        // APPEAL_TOTAL_WINDOW` through any door that exists — equality at the
        // very last permitted second is as far as it reaches, and that is a
        // measured property of two constants rather than an opinion. It is
        // written anyway, for the reason the two ternaries in this file are
        // written on unreachable states: the week is decision 244's one
        // absolute limit, and a limit that lives only inside another function's
        // subtraction is one edit away from being no limit at all. Whoever asks
        // "what stops this deadline leaving the week" is answered here, beside
        // the write, instead of having to prove a theorem about a door.
        {
            // The mark is already warm — `_lotThrow` read it in this same
            // transaction — so both reads here are about 100 gas, and that is
            // the whole bill the ordinary appellant pays for this branch. A
            // throw cannot be spent on an appeal with no filing stamp
            // (`_lotThrow` answers `NotOffered` for one), so the ceiling is
            // never built on a nought.
            if (ArbiterRegistryStorage.appealThrowsSpent(d, agreement) != 0) {
                uint256 ceiling =
                    ArbiterRegistryStorage.appealFiledAt(d, agreement) + APPEAL_TOTAL_WINDOW;
                uint256 fresh = block.timestamp + APPEAL_REVIEW_WINDOW;
                v.appealDeadline = fresh < ceiling ? fresh : ceiling;
            }
        }

        emit ArbiterRegistryFacet.AppealPanelSummoned(agreement, seedBlock, called);
    }

    /// @notice Who the chain called to this appeal, and the clock on the lot.
    ///
    /// One view and not three, because a screen needs all of it at once: an
    /// arbiter asks "am I on this panel" (the list, compared client-side), the
    /// appellant asks "is my panel being summoned yet" (`summoned`, and the two
    /// block numbers to say when), and both need to be able to tell "nobody has
    /// pulled the lot" from "the lot was pulled and came up short".
    ///
    /// @return panel      the summoned, packed from seat zero; the tail is zero
    /// @return summoned   how many were called — ZERO MEANS NOT PULLED YET, and
    ///                    a number below five means seats resolved to nobody
    /// @return corps      N, frozen when the appeal was raised
    /// @return seedBlock  the height the seed comes from; zero on an appeal
    ///                    raised before the lot existed, which can never have
    ///                    a panel
    /// @return seedExpiresAtBlock the last block at which the lot can be
    ///                    pulled; zero when there is no seed height at all
    function getAppealSummons(address agreement)
        external
        view
        returns (
            address[APPEAL_PANEL_SEATS] memory panel,
            uint256 summoned,
            uint256 corps,
            uint256 seedBlock,
            uint256 seedExpiresAtBlock
        )
    {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];
        summoned  = v.appealSummoned;
        corps     = v.appealCorps;
        seedBlock = v.appealSeedBlock;
        seedExpiresAtBlock = seedBlock == 0 ? 0 : seedBlock + APPEAL_SEED_HORIZON_BLOCKS;
        for (uint256 s; s < summoned; ++s) panel[s] = d.appealPanelSeats[agreement][s];
    }

    /// Was this man called to this appeal?
    ///
    /// Reads the seats and not a flag of its own: one record of who sits, so
    /// "who may vote" and "who was summoned" cannot drift apart. At most five
    /// cold reads, paid by the arbiter pressing the button — the one party here
    /// who is paid for the press.
    function _isOnAppealPanel(
        ArbiterRegistryStorage.Data storage d,
        address agreement,
        uint256 summoned,
        address who
    ) private view returns (bool) {
        for (uint256 s; s < summoned; ++s) {
            if (d.appealPanelSeats[agreement][s] == who) return true;
        }
        return false;
    }

    /// @notice What this appeal's panel looks like right now, for a screen that
    /// has to say "one seat left, two votes needed" without guessing a number.
    ///
    /// ⚠️ THE FIRST RETURN CHANGED MEANING ON 23 SEPTEMBER 2026 and was
    /// renamed with it, deliberately rather than quietly. It used to be
    /// `eligible` — arbiters who could vote, counted by walking the roster.
    /// There is no roster walk any more and nothing to count: the panel is
    /// APPEAL_PANEL_SEATS seats and a vote is a seat, so what a board actually
    /// needs to know is how many are left. A front end reading the old name
    /// gets a compile error instead of a number that means something else.
    ///
    /// ⚠️ A FOURTH RETURN WAS APPENDED ON 24 SEPTEMBER 2026 with the hour the
    /// seats stay shut. A screen that can only say "no" is the refusal this
    /// repository keeps finding on the far side of a press already decided on;
    /// with this number it says "in forty minutes" instead.
    ///
    /// Appended to THIS view rather than given a view of its own, and that is a
    /// deliberate choice about the CUT: a new function is a new selector, and a
    /// selector added beside a facet being replaced turns one `Replace` group
    /// into a `Replace` and an `Add`. Return values do not enter a selector —
    /// `getAppealPanel(address)` is the same four bytes it was — so the whole
    /// facet still goes in as a single clean Replace.
    ///
    /// ⚠️ `cast` COUNTS ONE DIRECTION FROM 14 OCTOBER 2026 (decision 177), and
    /// on an appeal raised before that cut it is therefore SHORT by however
    /// many votes to uphold it carried: those arbiters are still barred from
    /// voting again (`hasVotedAppeal`), but their seats no longer show as
    /// taken. Measured before the cut: no verdict was under appeal on the live
    /// diamond (`getDisputed()` answered an empty list on 14 October 2026), so
    /// there is nobody for this to mislead. The alternative — keeping a dead
    /// field inside the arithmetic of a live screen — is how the old count
    /// stayed believable long after it stopped meaning anything.
    ///
    /// @return seatsFree   seats on this appeal's panel nobody has taken
    /// @return required    votes to overturn; silence is the upholding
    /// @return cast        votes already in — the seats taken, the same number
    /// @return seatsOpenAt when an arbiter may first take one; zero when no
    ///                     appeal stands, because there is nothing to wait for
    function getAppealPanel(address agreement)
        external
        view
        returns (uint256 seatsFree, uint256 required, uint256 cast, uint256 seatsOpenAt)
    {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        cast      = v.votesOverturn;
        // ⚠️ FREE OF THE SUMMONED, NOT FREE OF FIVE (the lot, 14 October
        // 2026). It used to be `APPEAL_PANEL_SEATS - cast`, because a seat was
        // free for whoever pressed first; nobody presses into a seat any more,
        // so the only honest reading of "free" is "called and not yet voted".
        //
        // ⚠️ IT IS THEREFORE ZERO ON AN APPEAL WHOSE LOT HAS NOT BEEN PULLED,
        // where it used to be five, and a screen that reads only this number
        // would say "the panel is full" about a panel that does not exist yet.
        // `getAppealSummons` is what tells those two apart, and the browser is
        // held to asking: frontend/src/lib/appeal.ts answers
        // `summons.summoned === 0` before it looks at this number at all, and
        // frontend/src/i18n/appealSummonsHasItsOwnSentence.test.ts reddens if
        // that order is lost.
        uint256 summoned = v.appealSummoned;
        seatsFree = cast >= summoned ? 0 : summoned - cast;
        // Answered for a verdict with no appeal on it too, and the answer is
        // the same three: the bar no longer depends on anything that could have
        // changed between the quote and the appeal.
        required  = _overturnVotesRequired(d, agreement);
        // Read through the same helper the door reads, never recomputed here.
        seatsOpenAt = v.appealed ? _seatsOpenAt(d, agreement, v) : 0;
    }

    /// WHO MAY ANSWER A SUMMONS AT ALL, AND IT IS ONE DEFINITION READ BY BOTH
    /// DOORS OF THE PANEL (17 October 2026). Every refusal below stood inside
    /// `voteToOverturn` until the day the panel got a second thing it could do
    /// — `replyNoOverturn`, the answer that asks for no overturn — and both
    /// doors pay the same wage out of the appellant's deposit. A second copy of
    /// this list would have been two franchises promising to agree, which this
    /// file has said about `appealDepositFor` and about the bond: two copies of
    /// one formula agree only until the first edit.
    ///
    /// ⚠️ THE ORDER OF THE REFUSALS IS PART OF THE DEFINITION AND NOT TIDINESS.
    /// Each paragraph below says what it is doing above or below which other
    /// question, and several of those arguments are about what a man is TOLD
    /// rather than about what he is allowed: "too early" instead of "full",
    /// "the chain did not call you" instead of "come back in forty minutes".
    /// Moving a line here changes the sentence somebody reads at a door he has
    /// already decided to press.
    ///
    /// ⚠️ WHAT IS DELIBERATELY NOT IN HERE. The panel-full comparison and the
    /// price of a repeated vote stay at the vote door: the first is about the
    /// seats an OVERTURN takes, and the second is charged for asking for one.
    /// An answer that asks for no overturn takes no seat from the bar and pays
    /// no ladder — see `replyNoOverturn`, where both of those are argued.
    function _admitAnswerer(
        ArbiterRegistryStorage.Data storage d,
        ArbiterRegistryStorage.PendingVerdict storage v,
        address agreement,
        address caller
    ) private view {
        if (!d.isArbiter[caller]) revert ArbiterRegistryFacet.NotArbiter();
        // ⚠️ AND NOT WHILE HE IS SUSPENDED (14 October 2026). This door was
        // the one place that never asked. `_requireNotSuspended` guards
        // `claimDispute`, `resignAsArbiter` and `finalizeVerdict`, so a
        // suspended arbiter could not take a case, could not leave the corps,
        // and could not have his own verdict executed — and could still sit on
        // the panel reviewing somebody else's. Measured in
        // test/ArbiterRemovalByCapturedPanel.t.sol with the worst version of
        // that man: suspended by the chain AND carrying the chain's own
        // removal proposal against him, voting on another arbiter's verdict in
        // the same scene. The chain let a man it was itself prosecuting sit in
        // judgement on others.
        //
        // Asked of the CALLER, and asked here among the other questions about
        // the man — who he is, whether he still stands, whether he has ever
        // carried a case — all of which are one SLOAD. The appeal itself is
        // not read until those are answered, so a refusal stays cheap.
        //
        // It reads the CLOCK and not a flag, like every other caller of this
        // helper: the suspension lapses after SUSPENSION_WINDOW and the vote
        // comes back on its own, with nobody to press anything.
        ArbiterRegistryStorage.requireNotSuspended(d, caller);
        // ⚠️ THE QUESTION IS ASKED IN TWO PLACES AGAIN SINCE 16 OCTOBER 2026
        // (decision 187), AND THE SENTENCE THAT STOOD HERE — "this is the only
        // place the question is asked" — IS CORRECTED RATHER THAN DELETED,
        // because the reason behind it still governs. It used to be asked twice:
        // here, and over EVERY SEAT IN THE ROSTER inside `raiseAppeal`, which
        // made the appellant pay for the size of the corps and gave two counts
        // to keep in step. That walk is gone and must not come back.
        //
        // The second place now is `summonAppealPanel`, on the five seats the lot
        // draws — a fixed five at any corps size, and through THIS SAME HELPER,
        // never a copy of its condition. So there is one definition of the
        // franchise and nothing to keep in step; what there is not, any more, is
        // a count that grows with the roster.
        //
        // ⚠️ ONE CASE OF HIS OWN, CARRIED TO A VERDICT THAT STOOD — the
        // owner's replacement for the bond that used to stand here. A free seat
        // plus a paid vote is a hole anybody with addresses could work; a
        // record of work is not something a fresh wallet can bring. Hand-seated
        // arbiters are exempt, and on the day this lands that exemption is the
        // only reason an appeal can be reviewed at all. See `_mayVoteOnAppeals`.
        if (!_mayVoteOnAppeals(d, caller)) revert ArbiterRegistryFacet.NoAdjudicatedCase();
        if (!v.appealed) revert ArbiterRegistryFacet.NoAppeal();
        if (v.appealResolved) revert ArbiterRegistryFacet.AppealAlreadyResolved();
        if (caller == v.arbiter) revert ArbiterRegistryFacet.CannotVoteOnOwnVerdict();
        // ⚠️ NOR THE MAN WHO RAISED THE APPEAL (14 October 2026), under his
        // own name rather than as a side effect of the refusal below.
        //
        // Until today he was kept out TRANSITIVELY, and nothing said so:
        // `raiseAppeal` admits only a party to the deal, and the party check
        // below refuses parties, so the appellant was turned away for being a
        // party and never for being the appellant. `v.appellant` is written at
        // `raiseAppeal` and was read by nothing but the money paths. That
        // coincidence holds only while the registry record read below is
        // present and agrees with the clone — which is what the refusal after
        // this one now has to guarantee, and it did not before. A protection
        // that works only while another protection works is not a second
        // protection.
        //
        // ABOVE the party check deliberately, so the appellant is told the
        // real reason. `CannotVoteOnOwnDeal` stays reachable and stays
        // measured: it is the answer for the WINNING party, who is not the
        // appellant and whom nothing else keeps off this panel.
        //
        // Safe to read `v.appellant` here because `!v.appealed` was refused
        // above: on a standing appeal the field is always written.
        if (caller == v.appellant) revert ArbiterRegistryFacet.CannotVoteOnOwnAppeal();
        // ⚠️ NOR A PARTY TO THE DEAL (17 September 2026, journal item 199).
        // claimDispute already refused a party as the JUDGE; the panel had no
        // such check, so a party holding a bonded seat could cast one of the
        // three votes that decide where its own escrow goes. Read from the
        // registry's record of the deal rather than from the clone: the same
        // two addresses, written once at creation, without an external call.
        RegistryStorage.AgreementRecord storage rec = RegistryStorage.store().agreements[agreement];
        // ⚠️ AND THE RECORD HAS TO EXIST, OR THE LINE BELOW IT IS A NO-OP
        // (14 October 2026). The two doors of one appeal read the deal's
        // parties from two different places: `raiseAppeal` staticcalls the
        // clone's own `client()`/`executor()`, while this one reads the
        // registry's record, written once at registration
        // (`RegistryFacet._register`). On an agreement the registry never
        // recorded, `rec.client` and `rec.executor` are both the zero address,
        // every comparison below is false, and BOTH parties — including the
        // appellant, whose only cover this used to be — walk onto the panel of
        // their own deal.
        //
        // It is reachable, and that was measured before it was closed.
        // `claimDispute` and `submitVerdict` ask the AGREEMENT about itself and
        // never ask the registry, so any contract that answers `status()`,
        // `disputedAt()`, `DISPUTE_WINDOW()`, `client()`, `executor()` and
        // `setArbiter(address)` carries a dispute to a verdict and then to an
        // appeal with no record behind it at all. The scene is
        // test/AppealPanelAdmissionDoor.t.sol.
        //
        // Refused HERE and not at `raiseAppeal`: no money path is touched, so
        // an appeal raised on an unrecorded agreement simply finds no panel,
        // and nobody can answer it. The cost of the hole falls on whoever
        // manufactured it.
        //
        // ⚠️ AND THE SECOND HALF OF THAT SENTENCE WAS FALSE FROM
        // 17 OCTOBER 2026 UNTIL IT WAS CORRECTED ON THE 18th. It read
        // "`resolveAppeal`'s no-quorum branch sends the deposit home whole",
        // which was the state before the owner's decision of the 17th. From
        // the 18th it read that an unrecorded agreement is the one exception to
        // "nothing of a deposit reaches the bank", because `_theOtherSide`
        // reads the parties out of the REGISTRY, finds no record and answers
        // the zero address — so there was no party to cross to and the whole
        // deposit went to `vaultBalance`.
        //
        // ⚠️ THAT EXCEPTION CLOSED ON 19 OCTOBER 2026 and the bank is no longer
        // an addressee of any deposit at all. A silent appeal's deposit goes to
        // the TREASURY now, and this refusal is exactly why an unrecorded
        // agreement can take no other road: nobody can answer it, so
        // `_nobodyAnswered` is true of it always. What remains true is the
        // first half — the cost falls on whoever manufactured the contract, and
        // nobody is owed a wage out of it. Where it lands is written at the
        // bottom of `resolveAppeal`, with the measurement.
        //
        // `rec.agreement` and not `rec.client`: `_register` writes the key
        // into the record, so this compares the record against the address it
        // was found under instead of merely against a zero.
        if (rec.agreement != agreement) revert ArbiterRegistryFacet.NotRegisteredAgreement();
        if (caller == rec.client || caller == rec.executor) revert ArbiterRegistryFacet.CannotVoteOnOwnDeal();
        // ⚠️ AND THE CHAIN MUST HAVE CALLED HIM (the lot, 14 October 2026).
        // This is the refusal that ends self-selection: until today any
        // arbiter in good standing could take a seat by pressing before four
        // others did, so three addresses that had agreed in advance owned
        // every panel in the protocol at any corps size. Now five are drawn by
        // number in `summonAppealPanel` and everyone else is turned away here.
        //
        // TWO REFUSALS AND NOT ONE, because they are not the same news. "The
        // lot has not been pulled yet" is temporary and the caller can fix it
        // himself with one transaction; "the chain did not call you" is final
        // for this appeal and is nobody's fault. One sentence for both would be
        // the kind of dead end this file keeps finding on the far side of a
        // press somebody already decided to make.
        //
        // ABOVE THE CLOCK CHECKS deliberately: an arbiter who was never called
        // should hear that, and not be told to come back in forty minutes to a
        // door that will never open for him. BELOW the questions about the man
        // and the deal, which are one SLOAD each — the panel read is up to five.
        uint256 summoned = v.appealSummoned;
        if (summoned == 0) revert ArbiterRegistryFacet.AppealPanelNotSummonedYet();
        if (!_isOnAppealPanel(d, agreement, summoned, caller)) revert ArbiterRegistryFacet.NotOnAppealPanel();
        if (block.timestamp >= v.appealDeadline) revert ArbiterRegistryFacet.AppealWindowClosed();
        // ⚠️ AND NOT IN THE FIRST HOUR (24 September 2026, the owner's
        // decision). Checked BELOW the window and ABOVE the seat count, so that
        // an arbiter who is too early hears "too early" and not "full": the two
        // refusals send him away for very different lengths of time.
        uint256 openAt = _seatsOpenAt(d, agreement, v);
        if (block.timestamp < openAt) revert ArbiterRegistryFacet.AppealSeatsNotOpenYet(openAt);
        if (d.hasVotedAppeal[agreement][caller]) revert ArbiterRegistryFacet.AlreadyVoted();
    }

    /// @notice Votes to OVERTURN the verdict under appeal. Any arbiter in good
    /// standing who has carried a case of his own votes exactly once — except
    /// the one who ruled, the man who raised the appeal, and the two parties to
    /// the deal. A suspended arbiter is not in good standing and is refused for
    /// as long as the suspension runs. The agreement must be one the registry
    /// recorded; nothing on the panel can be decided about a deal whose parties
    /// the diamond does not know.
    ///
    /// ── THE VOTE HAS ONE DIRECTION (decision 177, 14 October 2026) ──
    ///
    /// This door was `voteOnAppeal(address agreement, bool overturn)` until
    /// today, and the bool is gone rather than pinned to `true`: a parameter
    /// that admits one value is a lie in the signature, and a caller who passed
    /// `false` had every right to expect something to happen. Nothing upholds a
    /// verdict here. A verdict stands because the hours ran out, and an arbiter
    /// who reads the appeal and disagrees with it simply does not come — his
    /// silence IS the upholding, it is free, and it is not written down.
    ///
    /// ⚠️ THE SELECTOR CHANGED WITH THE NAME. The old four bytes are REMOVED
    /// and the new ones ADDED in the cut that carries this facet, which is two
    /// groups where a facet replacement is usually one; `Replace` reverts on a
    /// selector that is not mounted and `Add` on one that is, and a mistake in
    /// the grouping takes down the whole `diamondCut` rather than one function.
    /// Both relay tables and the browser's ABI move in the same commit.
    ///
    /// ⚠️ WHY NOT A PENALTY FOR SILENCE, since silence can now bury an appeal:
    /// 177 considered one and refused it twice over. It would fine the only way
    /// left to disagree with a complaint, and it is a weapon with a known price
    /// — cheap deals, cheap appeals, and a counter ticking against every honest
    /// arbiter the chain was busy summoning. Redundancy cannot be turned into a
    /// weapon, so five seats absorb the silence of two instead.
    function voteToOverturn(address agreement) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        _admitAnswerer(d, v, agreement, caller);
        // ⚠️ FIVE SEATS, AND THE FIFTH IS THE LAST (decision 177, 14 October
        // 2026 — three until today). Whoever presses first takes a seat; the
        // sixth arbiter to arrive is refused, and the appeal is off the board.
        //
        // A VOTE IS THE SEAT — there is no separate claim, and that is a
        // decision and not an omission:
        //
        //   • a seat booked and never voted from is a seat nobody else can
        //     take. Five addresses that sit down and stay silent would kill
        //     every appeal in the protocol for the price of the gas, and an
        //     appeal is the only check a wrong verdict has;
        //   • ⚠️ THE SECOND REASON IS TRUE AGAIN, AND ITS TWO CORRECTIONS ARE
        //     KEPT BECAUSE THE PAIR SHOWS HOW LITTLE THE ARGUMENT DEPENDED ON
        //     THE MONEY. It first read "the panel's pay is already per vote
        //     cast, so 'who really sat' and 'who gets paid' stay ONE set". On
        //     16 October 2026 the panel stopped being paid at all, and the
        //     sentence was corrected to stand on the other side of the money:
        //     a vote is also what the GROWING FEE is charged on, so "who really
        //     sat" and "who PAID" stay one set. Since 17 October 2026 the panel
        //     is paid again — out of the appellant's deposit, divided by the
        //     number of men who ANSWERED — so the original reading holds once
        //     more, with `hasVotedAppeal` keying the wage for both doors. Three
        //     arrangements, one conclusion: two records of one fact agree only
        //     until the first edit.
        //
        // ⚠️ AND THE COUNT IS ONE FIELD NOW, where it used to be
        // `votesUphold + votesOverturn`: with one direction the sum had one
        // live term, and adding a permanent zero to it would be arithmetic
        // kept alive to look unchanged. On an appeal raised before this cut the
        // seats its uphold votes took stop showing as taken — nobody is let in
        // twice (`hasVotedAppeal` is above this line), and the live chain
        // carried no standing appeal when this was written.
        if (v.votesOverturn >= APPEAL_PANEL_SEATS) revert ArbiterRegistryFacet.AppealPanelFull();

        // ── WHAT A REPEATED VOTE COSTS (the owner's decision of 14 October
        //    2026, built 17 October) ────────────────────────────────────────
        //
        // Nought for the first vote of a run, dearer for every one after it,
        // and what is paid goes to the arbiter bank and comes back to nobody.
        // The ladder, the window and the arguments for all three numbers are at
        // ArbiterRegistryStorage.APPEAL_VOTE_FEE_WINDOW.
        //
        // ⚠️ CHARGED AFTER EVERY REFUSAL AND BEFORE EVERY WRITE. A vote that
        // the door turns away costs its man nothing but gas — he may be early,
        // or uncalled, or looking at a full panel — and a charge taken above
        // those refusals would be money taken for a vote that never happened.
        // Below them, the only way out of this function is the fee itself.
        //
        // ⚠️ THE PRICE IS KEYED ON THE PAIR (voter, THE JUDGE HE VOTES
        // AGAINST) SINCE 18 OCTOBER 2026, where it used to be keyed on the
        // voter alone. The decision put the price on REPEATING AN ATTACK, and
        // a counter per address charged something else: an arbiter who
        // answered five summonses against five different judges climbed the
        // ladder without having repeated anything, which is diligence being
        // billed. Measured in test/AppealVoteRepeatFee.t.sol.
        //
        // ⚠️ THE JUDGE IS READ OFF THE VERDICT UNDER APPEAL AND NEVER TAKEN
        // FROM AN ARGUMENT OF THIS DOOR. `v.arbiter` is the man who ruled on
        // this very deal, written by `submitVerdict`; a judge the caller could
        // name would let him stand on the first rung for ever by naming a
        // stranger every time. It cannot be the zero address here — an appeal
        // exists only over a submitted verdict — and it cannot be the caller
        // either, because `_admitAnswerer` turns the judge of the case away
        // above this line.
        //
        // ⚠️ WHAT MOVING THE KEY COSTS IS NOT HIDDEN: a campaign against a
        // FRESH target is a fresh run for every address in the circle, so the
        // ladder now charges one rung per target instead of a run that carried
        // across targets. test/ArbiterRemovalByCapturedPanel.t.sol prices both
        // readings side by side; the second removal turned from a loss into a
        // profit when the key moved, and that is a finding standing open and
        // not a thing this file settles.
        //
        // ⚠️ THE FEE FOLLOWS `_msgSender()`, WHICH IS WHY IT IS `caller` AND
        // NOT `msg.sender`. An arbiter reaches this door through the forwarder,
        // where `msg.sender` is the forwarder's own address: a fee keyed on it
        // would be charged to a contract that holds no USDC and has approved
        // nothing, so every gasless vote would revert while every direct vote
        // paid. That is not a guess — it is the shape of the bug that kept the
        // paid arbiter call from ever working, found on 31 July 2026 — and the
        // scene that holds it here drives a real `MinimalForwarder` rather than
        // pranking the facet, because a test that calls the facet directly
        // cannot see this class of defect at all.
        address judged = v.arbiter;
        (uint256 fee, uint256 run) = ArbiterRegistryStorage.appealVoteFeeAgainst(d, caller, judged);
        if (fee != 0) {
            address usdc = FactoryStorage.store().usdc;
            // ⚠️ THERE IS NO PRE-CHECK ON HIS WALLET OR HIS ALLOWANCE HERE, AND
            // THAT IS A DECISION TAKEN AGAINST THE FIRST DRAFT OF THIS WORK,
            // WHICH HAD ONE. The draft refused with a named error carrying
            // three numbers — the price, what he holds, what he has approved —
            // and that error could not ship: the refusal census (the
            // `pre-commit` hook, plus a sweep on each side of the relay)
            // requires every error declared under src/ to be decoded into its
            // NAME by BOTH relay tables, and those two tables live in
            // directories this piece of work was told not to touch. An error
            // nothing decodes reaches a person as four raw bytes, which is
            // worse for him than what he gets now.
            //
            // What he gets now is the TOKEN's own refusal, and it is readable:
            // Base USDC reverts inside `transferFrom` with "transfer amount
            // exceeds allowance" or "exceeds balance", the browser already
            // tells those two apart by name — the first is the allowance
            // sentence, the second is deliberately NOT — and the price itself
            // is on his card before he presses (`getArbiterStanding`), which is
            // where the number belongs anyway.
            //
            // ⚠️ WHAT IS LOST, SAID PLAINLY RATHER THAN LEFT TO BE FOUND: the
            // refusal no longer carries the figure, so a screen that wants to
            // say "ten dollars, and you hold nine" has to read the card for the
            // first half. Reinstating the named error is two one-line rows in
            // the two decode tables and nothing else in this facet.
            //
            // ⚠️ THE REFUSAL BELOW IS A SENTENCE AND NOT A CODE, THE WORDING IS
            // NOT FREE, AND IT STANDS ON THE LINE AFTER THE PULL ON PURPOSE.
            // The browser decides whether to say "your standing allowance ran
            // out, press again and you will be asked for the paper" by MATCHING
            // THE TEXT of the refusal, and `script/check-allowance-marks.sh`
            // holds every refusal that guards a pull against the list it
            // matches on — reading the SIX LINES after the pull, so a paragraph
            // wedged in between makes this door read as a pull with no answer
            // at all (measured: that is exactly what the gate said about the
            // first draft of these lines). "fee transfer failed" is a mark the
            // list already carries, the same one `FactoryFacet` is recognised
            // by, so this pull is answered on the screen the day it lands
            // without a new mark and without touching the browser. A custom
            // error of its own, however well named, matches nothing there.
            bool paid = IUSDCFull(usdc).transferFrom(caller, address(this), fee);
            require(paid, "ArbiterRegistry: vote fee transfer failed");
            // Into the bank, the one pot in this protocol every forfeit goes
            // to, and the pot appeal debts are paid out of. It never leaves
            // again on this man's account: there is no claim, no refund branch
            // and no road back, which is the whole of the decision that money
            // only has weight when it is lost. `bankAboveDebts` stays true by
            // arithmetic — the debts are untouched and the bank only grows.
            d.vaultBalance += fee;
        }
        // ONE statement for the clock and the counter, so a cooled run cannot
        // be written back with a stale time: `run` is already the cooled
        // reading (see `appealVoteFeeAgainst`), and this vote makes it one
        // longer. Both are keyed on the pair.
        d.lastAppealVoteAtAgainst[caller][judged] = block.timestamp;
        d.appealVoteStreakAgainst[caller][judged] = run + 1;
        // ⚠️ AND THE ONE FIELD THAT IS NOT PART OF THE PRICE: who he voted
        // against last, written for `getArbiterStanding` alone. A screen is
        // handed an address and no deal, so without this the card could not
        // name a pair at all and would have to print nothing. It is never read
        // by this door — the price above comes off the appeal — so a wrong
        // value in it could mislead a screen and could not misprice a vote.
        d.lastAppealVoteTarget[caller] = judged;

        d.hasVotedAppeal[agreement][caller] = true;
        v.votesOverturn++;

        // ⚠️ THE EVENT KEEPS ITS THIRD TOPIC AND IT IS NOW A CONSTANT `true`.
        // It is not a lie — this vote IS a vote to overturn — and the subgraph
        // indexes the event by its signature, so dropping the parameter would
        // move a seam that has nothing to do with this decision. A reader of
        // the feed can tell the two eras apart by the cut, not by the field.
        emit ArbiterRegistryFacet.AppealVoteCast(agreement, caller, true);
    }

    /// @notice ANSWERS THE SUMMONS WITHOUT ASKING FOR AN OVERTURN: "I read the
    /// appeal and I see no case in it." One of the summoned, once, inside the
    /// window, under exactly the conditions the vote door asks for — the list is
    /// `_admitAnswerer` and there is no second copy of it.
    ///
    /// ⚠️ WHY IT EXISTS, AND THE ANSWER IS ABOUT PAY AND NOT ABOUT PROCEDURE
    /// (17 October 2026, the owner). The panel is paid out of the appellant's
    /// deposit from today, and until this door existed there was exactly ONE
    /// payable act on a panel: voting to overturn. Decision 177 took the
    /// "uphold" direction away on purpose, so an arbiter who read the case and
    /// found it empty did nothing the chain could see and worked for nothing.
    /// A wage payable only for an overturn is a wage for overturning, which is
    /// the standing bias decisions 175 and 176 both named and left open as a
    /// gate on this very cut. This door closes it by making the HONEST reading
    /// of a weak appeal a PAID act at all, which is what the bias was about.
    ///
    /// ⚠️ AND WHAT THE TWO READINGS ARE WORTH IS EQUAL AT AND ABOVE A 20 USDC
    /// POT AND NOT BELOW IT — which is a PRICE the owner was shown and chose,
    /// not an oversight. The two readings are paid out of different pockets: a
    /// verdict left standing divides the appellant's DEPOSIT, a verdict
    /// overturned divides the judge's CASE BOND. The pot ceiling sits on the
    /// bond alone (`ArbiterRegistryStorage.caseBondFor`), so below a 20 USDC
    /// pot the bond is the pot while the deposit stays at its floor: measured
    /// on a 5 USDC pot with three answerers, leaving a bad verdict standing
    /// pays 5.000000 each against 1.250000 for overturning it. Below that pot a
    /// panel is therefore better off leaving the verdict alone, and the bias
    /// decisions 175 and 176 named is not removed there — it is inverted.
    ///
    /// ⚠️ THOSE TWO FIGURES READ 6.666666 AND 1.666666 UNTIL 20 OCTOBER 2026,
    /// and they are marked here rather than wiped because of HOW they were
    /// wrong. They were the whole pocket divided by the turnout, which is the
    /// rule of 17-19 October; since the evening of the 19th the men who
    /// answered divide THREE QUARTERS of it and the last quarter leaves as a
    /// toll. The RATIO between the two numbers — fourfold, which is the only
    /// thing the paragraph around them argues from — did not move, so the
    /// sentence went on reading as true at the wrong figures. Re-derived by
    /// hand: a 5 USDC pot prices the appeal at the 20 USDC floor, so the
    /// standing road divides 20.000000 x 3 / 4 = 15.000000 three ways, and the
    /// overturn road divides the bond, min(20, 5) = 5.000000, x 3 / 4 =
    /// 3.750000 three ways.
    ///
    /// ⚠️ AND IT WAS CLOSED FOR ONE DAY BY MERGING THE SIZERS, WHICH IS THE
    /// PARAGRAPH THIS REPLACES. On 19 October 2026 the same ceiling was put on
    /// the deposit, the two pockets became one number on every pot, and this
    /// docstring said the dependence on the outcome was gone. What that cost
    /// was measured the next morning: the appeal price lost its 20 USDC floor
    /// wherever the pot was smaller, taking with it the only brake on a junk
    /// appeal against a dust deal and the truth of four sentences on screen.
    /// The owner's decision of 18 October — "the bond only" — was confirmed on
    /// 20 October, so the floor is back on the price and the inequality below
    /// 20 USDC is back with it, written down here instead of being asserted
    /// away. The equality that IS held, outcome against outcome at and above
    /// that pot, is in test/AppealWageIsOutcomeBlind.t.sol.
    ///
    /// ⚠️ IT DECIDES NOTHING, AND THAT IS THE WHOLE OF ITS RELATION TO THE BAR.
    /// Three of the summoned asking for an overturn flip the verdict; this
    /// answer enters that comparison in NEITHER direction. It is not half a vote
    /// against, it does not raise the bar, it does not lower it, and it cannot
    /// bury an appeal: decision 176 named the shape, "an answer to the summons
    /// and not a vote". A verdict still stands because the hours ran out.
    ///
    /// ⚠️ ONE ACT PER MAN, NOT TWO, and the lock is `hasVotedAppeal` — the same
    /// flag the vote door sets and reads, which is why answering here closes the
    /// vote door to him and voting closes this one. Two flags would have been
    /// two records of one fact; one flag makes the double wage arithmetically
    /// impossible rather than merely refused. Held by name in
    /// test/AppealPanelWage.t.sol.
    ///
    /// ⚠️ IT DOES NOT CHECK FOR A FULL PANEL, AND THAT IS ARITHMETIC AND NOT AN
    /// OMISSION. `_admitAnswerer` admits only the summoned and only once each,
    /// so `votesOverturn + appealReplies[deal]` can never exceed the summons
    /// count, which the lot caps at APPEAL_PANEL_SEATS. There is no state in
    /// which a sixth man could answer, so a comparison against five is a branch
    /// nothing can reach — and this file has had enough of those.
    ///
    /// ⚠️ IT IS FREE OF THE REPEAT-VOTE LADDER, AND THE PRICE OF THAT IS NAMED
    /// RATHER THAN HIDDEN. The ladder exists to make a CAMPAIGN of overturns
    /// expensive; charging it here would charge an arbiter for reading honestly
    /// and finding nothing, which is the one thing decision 176 measured as
    /// having to stay at zero ("if an arbiter who votes now and then pays
    /// anything at all, the window is too narrow"). What it costs on the other
    /// side is what this door leaves open, and it is spelled out here rather
    /// than pointed at a document: an attacker holding one seat the lot happens
    /// to summon can answer here for the price of gas and take back THREE
    /// QUARTERS of his own deposit, IF nobody else on the panel answers.
    ///
    /// ⚠️ THE MISSING QUARTER IS THE WALL, AND IT IS WHY THIS PARAGRAPH NO
    /// LONGER ENDS AT TURNOUT. It said "the defence against that is the wage
    /// itself — every other answerer halves his recovery — and it is turnout
    /// rather than a wall", which was true and was the defect: turnout is a
    /// number nobody knows in advance, and the attack cost his circle NOUGHT
    /// whenever nobody else answered (item 322, measured as an equality at
    /// zero). Since 19 October 2026 the toll leaves his circle on every lost
    /// appeal whatever the turnout, so the cheapest form of this attack costs
    /// him a QUARTER of the price and dilution by turnout is a bonus on top
    /// rather than the mechanism.
    ///
    /// `_msgSender()`, never `msg.sender`: an arbiter reaches this through the
    /// forwarder, where a raw sender is the forwarder's own address, which was
    /// summoned to nothing. The scene that holds it drives a real
    /// `MinimalForwarder` rather than calling the facet, because a test that
    /// calls the facet directly cannot see this class of defect at all.
    function replyNoOverturn(address agreement) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        _admitAnswerer(d, v, agreement, caller);

        d.hasVotedAppeal[agreement][caller] = true;
        d.appealReplies[agreement]++;

        emit ArbiterRegistryFacet.AppealNoCaseReplied(agreement, caller);
    }

    /// Whether NOT ONE of the men this appeal's lot summoned answered it at
    /// all — the one condition that sends the deposit to the TREASURY rather
    /// than to the men who read the case or home to the appellant (19 October
    /// 2026, the owner; it sent the deposit across to the other side of the
    /// deal from the 17th until then).
    ///
    /// ⚠️ IT IS ASKED FIRST OF THE THREE, AND THAT ORDER IS LOAD-BEARING. In
    /// `resolveAppeal` this predicate is the OUTER fork and `overturn` the inner
    /// one, so silence wins over an overturn wherever a bar of nought could ever
    /// make the two true together. The judge's bond is then never touched by a
    /// settlement nobody worked on, and the sentence "nobody answered, so there
    /// is nobody to pay" has no exception.
    ///
    /// ⚠️ IT READS TWO COUNTERS AND NOTHING ELSE, AND THEY ARE THE TWO THINGS
    /// THE PANEL CAN DO. `votesOverturn` is the men who asked for an overturn,
    /// `appealReplies[deal]` the men who read the case and asked for none;
    /// their sum is the panel's size for the division of the wage, and their
    /// sum being zero is silence. Both survive the window and the settlement —
    /// nothing clears them (held by test/AppealLot.t.sol) — and decision 178
    /// was built to guarantee exactly that, for exactly this reader.
    ///
    /// ⚠️ IT DOES NOT READ `appealSummoned`, AND DECISION 179 HAD TO. 179's
    /// question was whether none OF THE SUMMONED voted, because the answer
    /// decided whether to CHARGE the appellant; "nobody was called" and "five
    /// were called and all five stayed away" had to be told apart for exactly
    /// that reason. Nothing turns on that distinction now — the appellant loses
    /// the deposit either way and the panel earns nothing either way — so the
    /// two are one answer.
    ///
    /// ⚠️ IT DECIDES A DESTINATION AGAIN, AND THIS PARAGRAPH SAID THE OPPOSITE
    /// UNTIL 18 OCTOBER 2026 (evening) — "a size and no longer a destination",
    /// which was true for the one day the half crossed on every outcome. With
    /// the half gone the predicate chooses who gets the money AND how much of
    /// it, and since 19 October 2026 the two roads no longer share an
    /// addressee: silence sends the WHOLE deposit to the TREASURY, a lost
    /// appeal somebody read sends a QUARTER to the other side of the deal.
    ///
    /// ⚠️ THE NAME `_panelReadAndRefused` MUST NOT COME BACK. It was decision
    /// 176's condition, which 177 made unobservable and which nothing ever
    /// emitted; the distinction between "a panel read it and refused" and
    /// "nobody read it" was closed AS IMPOSSIBLE. It is observable again —
    /// `appealReplies` is exactly "a panel read it and refused" — but it buys
    /// the appellant nothing, because the deposit is not a forfeit he can
    /// escape in any branch. A reader who revives the old name to charge
    /// somebody is reviving a charge, not a distinction.
    function _nobodyAnswered(
        ArbiterRegistryStorage.Data storage d,
        ArbiterRegistryStorage.PendingVerdict storage v,
        address agreement
    ) private view returns (bool) {
        return v.votesOverturn == 0 && d.appealReplies[agreement] == 0;
    }

    /// @notice Settles the appeal vote. It may be called as soon as the bar is
    /// reached, without waiting for the window to end — nothing can take an
    /// overturn back, because votes only arrive and only point one way. Below
    /// the bar it waits for the window: the next vote could still cross it. If
    /// the window closes with fewer than APPEAL_OVERTURN_VOTES arbiters having
    /// voted, the verdict stands — and the deposit is spent, on the addressees
    /// named below (nothing hangs forever, and nothing comes back to a man
    /// whose appeal did not carry).
    ///
    /// ⚠️ THIS SENTENCE HAS BEEN WRONG TWICE AND IN OPPOSITE DIRECTIONS, which
    /// is the reason it now names the OUTCOME instead of the clock. It said
    /// "and the deposit goes home whole" until the morning of 18 October 2026,
    /// three paragraphs above the branch that refused it; it was corrected to
    /// "nothing comes back" that morning, and by that evening the owner had put
    /// a road home back — for a WON appeal only. A sentence that reads as a
    /// remark about the window rather than about the money is exactly how a
    /// stale line survives in a file that otherwise argues with itself at
    /// length, so this one says which outcome it is talking about.
    ///
    /// ⚠️ THE OUTCOME IS A BAR AND NO LONGER A MAJORITY (decision 177,
    /// 14 October 2026). What stood here reasoned about ties, about four cast
    /// two each, and about a threshold read off the quorum versus off the votes
    /// — every one of those states needed a second direction, and there is
    /// none. Three votes to overturn flip the verdict; two, one or none leave
    /// it standing. A tie cannot exist, so nothing waits for one.
    ///
    /// ⚠️ WHERE THE DEPOSIT GOES (the owner's decision of 19 OCTOBER 2026,
    /// which splits the pocket of the 18th into a WAGE and a TOLL — and read
    /// the branch below before changing a line of it). THE OUTCOME OF THE
    /// APPEAL DECIDES IT, and there are exactly three roads:
    ///
    ///   appeal WON        → the deposit goes HOME TO THE APPELLANT, whole, and
    ///                       the panel is paid by the man whose mistake they
    ///                       corrected: THREE QUARTERS of the OVERTURNED
    ///                       JUDGE'S CASE BOND, divided equally among the men
    ///                       who answered. The quarter that is left is the toll
    ///                       and it goes TO THE TREASURY. The bond no longer
    ///                       reaches the appellant at all.
    ///   appeal LOST, and  → THREE QUARTERS of the deposit are divided equally
    ///   somebody read it    among the men who ANSWERED the summons, and the
    ///                       quarter that is left — with the remainder of the
    ///                       division inside it — crosses to the other side of
    ///                       the deal. Answering means a vote to overturn
    ///                       (`voteToOverturn`) or a reading that asks for none
    ///                       (`replyNoOverturn`): the wage is for the work and
    ///                       not for its outcome. Each man pulls his own with
    ///                       `withdrawAppealShare`.
    ///   nobody answered   → the WHOLE deposit to the TREASURY (the owner,
    ///                       19 October 2026; it went to the other side of the
    ///                       deal from the 17th until then). Nobody
    ///                       deliberated, so there is nobody to pay a wage to;
    ///                       the argument for the addressee is written out in
    ///                       the branch itself, with the number that moved it,
    ///                       because the rule above turns on the appeal's
    ///                       OUTCOME and silence is not an outcome — so this
    ///                       road has to be argued on its own ground rather
    ///                       than derived from the other two.
    ///
    /// ⚠️ ONLY THE LOSER PAYS, AND FROM TODAY THAT IS THE PLAIN READING RATHER
    /// THAN A CLEVER ONE. The sentence was true yesterday too, by a route worth
    /// knowing because its collapse is what caused this rewrite: the deposit was
    /// spent on every outcome and a right appellant was made whole by catching
    /// the judge's bond instead — so the bond was OBLIGED to equal the deposit,
    /// and the guarantee of decision 173 rested on two pricing functions
    /// agreeing. They stopped agreeing on 18 October, when the pot ceiling held
    /// the bond — and only the bond — down to the deal's pot: on a $1 pot the
    /// deposit was still $20, the bond $1, and a WINNING appellant was down
    /// nineteen dollars for correcting somebody else's mistake. A refund needs
    /// no equality. He gets back exactly what he paid, on a pot of any size.
    ///
    /// ⚠️ THEY WERE MADE EQUAL AGAIN ON 19 OCTOBER 2026 — one sizer, one
    /// ceiling — AND PARTED AGAIN ON THE 20TH, when the owner confirmed "the
    /// bond only" and the ceiling went back onto `caseBondFor` alone. That
    /// churn is exactly why the refund does not depend on the equality: it is
    /// a property of today's prices, the guarantee has to hold whatever they
    /// are, so it is written as a refund of what he paid and not as a swap.
    ///
    /// ⚠️ A QUARTER CROSSES TO THE OTHER SIDE ON A LOST APPEAL AND THAT IS NOT
    /// THE HALF OF 17 OCTOBER COMING BACK. The half was charged on EVERY
    /// outcome, a right appellant included, and the owner removed it himself,
    /// twice saying he did not see why anything should go to the opposing
    /// party. The quarter is charged on ONE outcome only — an appeal that did
    /// not carry — so the man who was right pays nothing to anybody, and the
    /// man who was wrong pays a quarter rather than a half. What the quarter is
    /// FOR is the sentence the whole deposit could not keep: a junk appeal must
    /// cost its author something no matter how many seats he holds. With the
    /// whole deposit paid out as a wage it cost a one-seat circle NOUGHT —
    /// measured, item 322 — because he collects it as a reader and needs no
    /// refund.
    ///
    /// ⚠️ THE BANK GETS NOTHING OUT OF A DEPOSIT ANY MORE, and that sentence has
    /// no exception to remember: not the silent branch, not the division's
    /// remainder, not the toll. It is the rule most easily undone by accident,
    /// because what it replaced looked harmless: the deposit fed the very pot
    /// the panel is paid FROM, so a silent panel was paid for its silence out of
    /// a kitty it draws from itself. Held by a scene of its own for exactly
    /// that reason.
    ///
    /// ⚠️ THE TREASURY IS NOT THE BANK, and a reader who takes the toll's
    /// addressee for the arbiter fund has the whole decision backwards.
    /// `treasurySlice` is pushed out to `FactoryStorage.feeRecipient` by the
    /// open `ArbiterVaultFacet.withdrawTreasurySlice`; `arbiterRewards` and
    /// `vaultBalance` are the corps' own money and the corps must not earn out
    /// of complaints about the corps.
    ///
    /// ⚠️ FIVE ARRANGEMENTS IN FIVE DAYS, AND THE READER OF AN OLD LOG NEEDS THE
    /// DIFFERENCES MORE THAN HE NEEDS TODAY'S RULE.
    ///
    ///   until 14 Oct  the deposit was the panel's pay on every outcome AND on
    ///                 an overturn the appellant was made whole a second time
    ///                 out of the judge's bond, out of the bank, and failing
    ///                 both as a debt against him. With a SELF-SEATED panel that
    ///                 is a profit: test/ArbiterRemovalByCapturedPanel.t.sol
    ///                 priced two addresses holding two of three seats at
    ///                 +$18.97 PER CAPTURED APPEAL.
    ///   14–16 Oct     decision 171: the deposit went home when anybody voted
    ///                 and burned into the bank when nobody did, the panel was
    ///                 paid the judge's forfeited fee share, and the bond burned.
    ///   16–17 Oct     item 301: the fee share went to the appellant, so the
    ///                 panel was paid NOTHING and had one payable act — the
    ///                 overturn. Income nil, and a standing bias toward
    ///                 overturning, which decisions 175 and 176 both named.
    ///   17–18 Oct     the deposit was spent on EVERY outcome: half across to
    ///                 the other side always, the rest the panel's wage, nothing
    ///                 home ever — and a right appellant was made whole by
    ///                 catching the overturned judge's bond instead. It held
    ///                 only while bond and deposit were the same number, and
    ///                 the pot-measured bond of that same evening broke it.
    ///   18–19 Oct     the deposit goes home if the appeal carried and is the
    ///                 panel's wage, WHOLE, if it did not. It cost a circle
    ///                 holding one seat nought (item 322): the attacker took his
    ///                 own deposit back as a WAGE, so the refund rule never
    ///                 reached him and nothing stood in the way.
    ///   from 19 Oct   this rule: the same two pockets, each split three
    ///                 quarters to the men who read the case and one quarter out
    ///                 of the appellant's reach. The quarter is what the whole
    ///                 pocket could not be — a cost a junk appeal cannot take
    ///                 back through a seat of its own.
    ///
    ///
    /// The judge's forfeited fee share goes to the BANK, in
    /// `ArbiterVaultFacet._settleForfeitedShare`, which is where that share
    /// first exists: `creditDisputeFee` runs inside the `finalizeVerdict` this
    /// very call unblocks (the seam is measured in
    /// test/AppealFeeTimingSeam.t.sol). So the judge loses exactly what he lost
    /// yesterday, bond and share together, and only the addressees moved.
    ///
    /// ⚠️ THE DEBT MACHINERY IS LEFT STANDING AND IS NO LONGER FED. Nothing
    /// writes `appealLedgers.debt`, `advanceFromBond` or `advanceFromVault` any
    /// more; `settleAppealDebts` and the first arms of `_settleForfeitedShare`
    /// exist for appeals settled before this cut, whose appellants were promised
    /// money that has to keep its two ways out. `voterShare` is written again
    /// from today, and by THIS call rather than by the fee's.
    ///
    /// ⚠️ NO LOOP OVER THE PANEL, and none may be added. This is the only door
    /// that unfreezes the escrow; a payout per man inside it would give it a
    /// cost that grows with turnout, and the day it ran out of gas the escrow
    /// would be frozen for good. The wage is written as ONE number and each man
    /// pulls his own through `withdrawAppealShare`.
    function resolveAppeal(address agreement) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[agreement];

        if (!v.appealed) revert ArbiterRegistryFacet.NoAppeal();
        if (v.appealResolved) revert ArbiterRegistryFacet.AppealAlreadyResolved();

        // THE BAR, AND THERE IS NOTHING ELSE TO WEIGH. The votes all point one
        // way (decision 177), so this is a comparison and not a tally: at or
        // above the bar the verdict is overturned, below it the verdict stands.
        // The bar is a constant now (see `_overturnVotesRequired`), except for
        // the handful of appeals raised in the five days it was frozen per
        // appeal.
        bool overturn     = v.votesOverturn >= _overturnVotesRequired(d, agreement);
        bool windowClosed = block.timestamp >= v.appealDeadline;
        // ⚠️ EARLY ONLY ON AN OVERTURN, and the reasoning about ties that used
        // to stand here is gone with the second direction (decision 177).
        // Anyone may press this door. Above the bar there is nothing left for
        // another arbiter to change — votes only arrive, and every one of them
        // says the same thing — so settling at once costs the appeal nothing.
        // BELOW the bar the window has to run out first: the vote that crosses
        // it may still be on its way, and a man who was about to lose would
        // otherwise press "settle" at exactly the wrong second and buy the win
        // the next arbiter was about to take away.
        // ── OR WHEN THE PANEL CAN NEVER ASSEMBLE (the lot, 14 October 2026) ─
        //
        // The third way out, and the answer to "he raised an appeal and walked
        // away". The lot has one window of about eight and a half minutes; if
        // nobody pulled it in that window, no vote can ever arrive, because
        // `voteToOverturn` admits only the summoned and nobody was summoned.
        // Waiting out the remaining four days would then hold the verdict
        // frozen and the deposit on the diamond for a result already decided.
        //
        // ⚠️ IT IS NOT A SHORTCUT PAST THE RULE ABOVE. That rule exists
        // because a vote that crosses the bar may still be on its way; here
        // there is provably no such vote, and the two conditions are what
        // prove it: nobody was called, and nobody can be called any more.
        //
        // ⚠️ IT ALSO SETTLES EVERY APPEAL RAISED BEFORE THE LOT EXISTED, by
        // the `appealSeedBlock == 0` arm. Such an appeal can never have a
        // panel, so it resolves at once: verdict standing, and the whole
        // deposit to the treasury — nobody can have answered such an appeal,
        // so there is nobody to pay a wage out of it.
        // The live diamond held no standing appeal on 14 October 2026
        // (`getDisputed()` answered an empty list), so this arm is a promise
        // to a state nobody is in rather than a migration anybody will feel.
        // ⚠️ THE SENTENCE ABOVE ENDED "deposit home whole" UNTIL
        // 18 OCTOBER 2026, which was the rule until the owner's decision of
        // the 17th.
        //
        // WHAT IT COSTS THE WINNING PARTY, since this is the door he is
        // waiting at: a verdict in his favour used to be frozen for four days
        // by an appeal nobody ever reviewed. Now an abandoned appeal unfreezes
        // it in about nine minutes, for the price of one transaction anybody
        // may send.
        //
        // ⚠️ THE DEPOSIT DOES NOT COME HOME ON THIS BRANCH — IT IS SPENT
        // WHOLE, AND IT TAKES NO ARGUMENT TO SHOW WHICH BRANCH DECIDES IT.
        // These lines said "THE DEPOSIT COMES HOME ON THIS BRANCH" until
        // 18 OCTOBER 2026, in the same door as the branch that does the
        // opposite and far enough from it to survive a reading. Under the
        // owner's decision of 19 October 2026, `_nobodyAnswered` sends the
        // WHOLE deposit to the TREASURY, and nothing of it comes back to the
        // man who paid it. ⚠️ IT READ "to the other side of the deal" FROM
        // 17 UNTIL 19 OCTOBER, and the addressee moved because the other side
        // could be the appellant's own second address; the half of the sentence
        // that matters at this door — nothing comes home — is the half that
        // did not change.
        //
        // The construction that made the old sentence provable is what makes
        // the new one provable, and it has not moved: an appeal whose lot was
        // never pulled admits no answer at all — `_admitAnswerer` refuses
        // everybody with `AppealPanelNotSummonedYet` — so `votesOverturn` and
        // `appealReplies` are both zero here, which is precisely the branch
        // `_nobodyAnswered` answers for.
        //
        // ⚠️ THE COUPLING THAT STOOD HERE IS GONE, AND THAT IS A SIMPLIFICATION
        // RATHER THAN A LOSS. Under decision 179 these lines and the forfeit
        // were "the same test read from opposite ends", both turning on
        // `appealSummoned == 0`, and a change to one that did not move the other
        // would have made an appeal both dead and forfeitable. The forfeit is
        // gone, so there is no second end left to keep in step: this condition
        // now only decides WHEN the settlement may be pressed, never where the
        // money goes.
        // ── AND NOT WHILE A THROW OF THE LOT IS STILL IN IT
        //    (29 October 2026, decision 244) ──
        //
        // ⚠️ WITHOUT THIS CONJUNCT THE REPAIR IS WORTH NOTHING, and that is
        // worth stating as a measurement rather than a worry. The settlement
        // door is permissionless; the other side of the deal is the party who
        // GAINS from a lot nobody pulled — the verdict in his favour stops
        // being frozen, and the appellant's price is spent (decision 200
        // sends it to the TREASURY, so what pressing this door buys him is
        // the escrow and not the money); so the instant the seed went stale —
        // 51 seconds after the filing — he would press this door and take it,
        // and the appellant's one throw would never have existed.
        //
        // ⚠️ THE PARENTHESIS READ "decision 200 sends him the whole price"
        // WHEN IT WAS WRITTEN ON 29 OCTOBER 2026 — the rule of 17 October,
        // retired by the owner on the 19th. It is quoted rather than erased
        // because of what it does NOT change: a man who gains only an
        // unfreezing still presses the door in the first minute, so the
        // conjunct above never rested on the addressee of the price. The right to throw again and
        // the right to settle are the same question read from opposite ends,
        // so they are read through the same function.
        //
        // ⚠️ IT DOES NOT REACH THE BRANCH WHERE FIVE WERE SUMMONED AND NOBODY
        // ANSWERED, and cannot: the first conjunct is `appealSummoned == 0`.
        // That branch keeps its own clock (`windowClosed`) and every line of
        // its money (decision 200). What this changes is only WHEN an appeal
        // whose panel never assembled may be settled — never where its money
        // goes.
        //
        // ⚠️ AND IT STOPS HOLDING THE ESCROW THE MOMENT THE THROW IS GONE.
        // An appellant who spends it in the first minutes is back to today's
        // behaviour exactly: the lot is dead, this door opens, and nobody waits
        // a week for a man who has stopped trying.
        bool panelDead = v.appealSummoned == 0
            && (v.appealSeedBlock == 0
                || block.number > uint256(v.appealSeedBlock) + APPEAL_SEED_HORIZON_BLOCKS)
            && _lotThrow(d, agreement, v) != LotThrow.Open;
        if (!overturn && !windowClosed && !panelDead) revert ArbiterRegistryFacet.AppealWindowNotClosed();

        v.appealResolved = true;
        v.frozen         = false;

        address usdc  = FactoryStorage.store().usdc;
        uint256 deposit = _depositOf(d, agreement, v);

        // ⚠️ THE OUTCOME OF THE APPEAL DECIDES WHERE THE DEPOSIT GOES
        // (18 October 2026, the owner — and it replaces the rule of the 17th,
        // under which half of it crossed on every outcome and none of it ever
        // came home). "The other side" below is the party to the deal who did
        // NOT appeal — the one the appellant dragged back into a fight that
        // was over — and he is reached on ONE road only: an appeal SOMEBODY
        // READ and the appellant lost, where the quarter crosses to him.
        //
        // ⚠️ THAT ROAD WAS NAMED THE OTHER WAY ROUND HERE UNTIL 30 OCTOBER
        // 2026 — "from today he is reached on ONE road only: an appeal nobody
        // read" — and the inversion is kept rather than erased because it is
        // the shape of the mistake and not a slip of the pen: the sentence was
        // written on 19 October in the voice of the 18th, hours before the
        // owner's decision of that evening moved the silent road to the
        // treasury and left the READ road as the only crossing. The addressee
        // table twenty lines below has been right since that evening, so the
        // file disagreed with itself at two distances — which is the reading a
        // sweep for one phrase does not catch.
        //
        // ⚠️ THE FORFEITED DEPOSIT HAS THREE POSSIBLE ADDRESSEES AND TWO OF
        // THEM ARE BAD, which is still the whole argument wherever a deposit is
        // forfeited at all:
        //
        //   the arbiter bank  — refused. It pays a silent panel out of the pot
        //                       the panel is paid FROM, so doing nothing feeds
        //                       your own kitty. Measured 14 October 2026, and
        //                       the price of the move was ZERO: no vote to
        //                       cast, no seat to resign, and nothing further to
        //                       agree on.
        //   home to the man   — refused WHERE THE APPEAL DID NOT CARRY, and
        //                       this is the distinction the whole rewrite turns
        //                       on. If a LOST or an unread appeal sends the
        //                       deposit back, a junk appeal is FREE: one seat
        //                       the lot summons and does not answer from, and
        //                       the attacker is whole again. At a corps of five
        //                       or fewer the lot summons everybody, so he does
        //                       not even need luck. On a WON appeal the same
        //                       road is not mercy but arithmetic — he was
        //                       right, and a man who corrects somebody else's
        //                       mistake must not pay for having done it.
        //   those who read it — the men who ANSWERED, on a lost appeal. THREE
        //                       QUARTERS of it, because the work is the only
        //                       thing anybody did and because the last quarter
        //                       has to be money he cannot take back through a
        //                       seat of his own.
        //   the other side    — what is left on a lost appeal SOMEBODY READ:
        //                       the quarter, and the base units the fractions
        //                       truncated. ⚠️ THIS ROW ALSO READ "and the whole
        //                       deposit when nobody answered at all" UNTIL
        //                       19 OCTOBER 2026, and that road now ends at the
        //                       treasury instead; see the `_nobodyAnswered`
        //                       branch for the number that moved it.
        //   the treasury      — the same quarter on a WON appeal, out of the
        //                       judge's bond; AND THE WHOLE DEPOSIT WHEN NOBODY
        //                       ANSWERED AT ALL (19 October 2026). The other
        //                       side of the deal is the man who was wrong on a
        //                       WON appeal, so he is not an addressee there;
        //                       see the overturn branch.
        //
        // ⚠️ WHY A WALL AGAIN, AND WHY A QUARTER (the owner, 19 October 2026).
        // Decision 174 forbids a defence that leans on a number nobody knows,
        // and the size of the corps — or the turnout on one panel — is exactly
        // such a number. The refund rule alone did not obey it after all: it
        // defends the honest case, but a junk appeal is answered by the
        // attacker's OWN seat, so he collects the pocket as a WAGE and never
        // needs a refund. Measured at NOUGHT with one seat (item 322). A
        // quarter that leaves his circle is arithmetic in the sense 174 asks
        // for: it is the same quarter at any turnout, and at one seat it is the
        // whole cost of the attack. The paragraph that stood here said "a junk
        // appeal costs its author THE WHOLE DEPOSIT and not half of it, because
        // the only road home is a verdict overturned, and the number of seats
        // he holds cannot change that" — the first half was true of the deposit
        // and false of his CIRCLE, which is the pocket that decides whether an
        // attack pays. A self-seated panel
        // that overturns gets the deposit home, but then the deal's verdict is
        // flipped and the bond is the wage, which is the campaign the lot and
        // the pot-measured bond are priced against.
        //
        // ⚠️ AND NOTHING OF THE DEPOSIT REACHES THE BANK ANY MORE, and since
        // 19 OCTOBER 2026 THE QUALIFIER THAT STOOD HERE IS GONE WITH THE
        // EXCEPTION IT NAMED. That is the half of item 303 a reader is most
        // likely to undo by accident, so it is held by a scene of its own.
        //
        // ⚠️ THE QUALIFIER READ "— ON A DEAL THE REGISTRY RECORDED", added on
        // 18 October 2026 over an earlier "in any branch", and the exception it
        // named was an agreement the registry never recorded — a contract
        // somebody manufactured that answers the handful of signatures
        // `claimDispute`, `submitVerdict` and `raiseAppeal` ask it for.
        // `_theOtherSide` reads the parties out of the REGISTRY and finds no
        // record, so it answers the zero address, there was nobody to cross to,
        // and the whole deposit landed in `vaultBalance` at the bottom of this
        // function. The absolute claim was measured and refused in
        // test/AppealPanelAdmissionDoor.t.sol before that line was written, so
        // it was wrong from the day it was committed.
        //
        // What closed it was not a fix to that branch but the owner's decision
        // of 19 October 2026: a silent appeal's deposit now goes to the
        // treasury, nobody can answer an unrecorded appeal (`_admitAnswerer`
        // refuses with `NotRegisteredAgreement`), so a manufactured agreement
        // only ever takes the silent road and the zero-address fallback is not
        // reached by anything known. ⚠️ THE FALLBACK IS STILL THERE AND MUST
        // STAY — unreachable is a measurement of this tree, not a property of
        // the code; the argument for keeping it is written beside it. Its lock
        // is test/AppealPanelWage.t.sol's
        // `test_AManufacturedAgreementTakesTheSilentRoadToTheTreasuryAndItCostsItsMakerTheLot`,
        // and it is GREEN: it drives a manufactured agreement down the silent
        // road and asserts the bank does not move. ⚠️ THE SENTENCE HERE SAID
        // THAT LOCK WAS RED "and that red is the measurement of this
        // paragraph", WHICH IT IS NOT. The scene was retargeted on 19 October
        // 2026 and measures the closure positively; a red in it today would be
        // a defect and not a measurement, and a paragraph that expects red
        // teaches the next reader to ignore one.
        uint256 answered = v.votesOverturn + d.appealReplies[agreement];
        address otherSide = _theOtherSide(agreement, v.appellant);
        uint256 toOtherSide;
        // THE TOLL'S OTHER ADDRESSEE, AND IT IS A SEPARATE VARIABLE FOR THE SAME
        // REASON `toOtherSide` IS ONE: the money of this settlement is decided
        // here and DISPATCHED once, below, so that no road can pay twice and
        // none can pay nothing. It is credited to `treasurySlice` rather than
        // transferred, like every other credit to it: a blocked fee recipient
        // must not be able to hold up the door that unfreezes an escrow.
        uint256 toTreasury;

        // WHAT THE OUTCOME PUTS ON THE TABLE, AND IT IS NOT ALWAYS THE SAME
        // MONEY — which is the one thing to hold on to in this function since
        // the owner's decision of 18 October 2026. The verdict STOOD: the
        // appellant's deposit is the pocket. The verdict FELL: the deposit goes
        // home to him whole and the OVERTURNED JUDGE'S CASE BOND is the pocket
        // instead. One variable, because there is one pocket and one
        // `voterShare` field behind it, and a second source would have to be a
        // second field.
        //
        // ⚠️ IT IS THE POCKET AND NOT THE WAGE SINCE 19 OCTOBER 2026, and the
        // rename is the decision rather than a tidy-up: the men who answered
        // divide THREE QUARTERS of it and the last quarter leaves the
        // appellant's circle as a toll. A reader who still takes this number
        // for the wage will compute every figure below a third too high.
        uint256 pocket;

        // Read through the predicate rather than off `answered` so that the
        // condition has ONE definition and the reasoning behind it sits beside
        // it; the sum above is what the division needs, not a second test.
        //
        // ⚠️ THE DIVISION IS NESTED INSIDE THE `else` AND NOT HUNG OFF A
        // SECOND TEST, and that is a decision rather than a shape. The wage
        // comes from two different pockets now, which invites writing the
        // division once below a flat `if / else if / else` — and that needs the
        // silence question asked a SECOND time, from a local, where the one
        // sentence this function must never lose becomes invisible to the lock
        // that watches it (test/AppealDepositFateMeasured.t.sol reads this very
        // line out of the source). Nested, the predicate is called once, the
        // reader sees "silence" and "somebody worked" as the first fork, and
        // `answered != 0` inside the else is structural rather than argued:
        // `answered` is nought exactly when `_nobodyAnswered` is true.
        if (_nobodyAnswered(d, v, agreement)) {
            // NOT ONE OF THE SUMMONED ANSWERED, so there is no panel to pay
            // and the whole deposit goes to the TREASURY. Three states land
            // here and all three are one fact — nobody did the work: a panel
            // was summoned and stayed silent, no panel was ever summoned (a
            // stale seed, or an appeal older than the lot, or a corps too small
            // to review anything), or the appeal is older than the answer door
            // itself.
            //
            // ⚠️ AND THIS IS THE ONE BRANCH THE RULE ABOVE DOES NOT DECIDE, SO
            // THE ARGUMENT FOR IT IS WRITTEN OUT HERE RATHER THAN LEFT AS A
            // NUMBER. That rule turns on the APPEAL'S OUTCOME, and it settles
            // the two roads that have a verdict behind them: won, and the
            // deposit goes home; lost, and it pays the men who read the case.
            // Silence is neither — there is no verdict on the appeal at all,
            // and nobody to pay — so the addressee here follows from the
            // candidates and not from the rule. Of those candidates:
            //
            //   home to the man  — refused, and this is the whole reason the
            //                      branch is not simply folded into the refund
            //                      above. If silence sends the deposit back, a
            //                      junk appeal is FREE: raise it, answer from
            //                      nobody, and be whole again. That is exactly
            //                      the defect "a junk dispute pays off", and it
            //                      would be reintroduced by a branch that looks
            //                      like mercy.
            //   the arbiter bank — refused by the decision on section 2 of this
            //                      protocol: the corps must not earn out of
            //                      complaints about the corps. A silent panel
            //                      would be paid for its silence out of the
            //                      very pot it draws from.
            //   the other side   — REFUSED SINCE 19 OCTOBER 2026, AND IT IS THE
            //                      ADDRESSEE THIS LINE CARRIED UNTIL THEN. The
            //                      argument for it was that it was the only
            //                      candidate left who did any part of the work:
            //                      nobody deliberated, but somebody WAITED —
            //                      the party who won the verdict was held out
            //                      of his money for four days by an appeal that
            //                      was never read.
            //
            //                      ⚠️ THAT ARGUMENT IS NOT WRONG ABOUT THE
            //                      WAITER. It is wrong about the chain's
            //                      ability to FIND him. "The other side" is
            //                      read out of the registry's record by
            //                      `_theOtherSide`, and the only thing in this
            //                      protocol that refuses one man holding both
            //                      sides of a deal is ADDRESS EQUALITY —
            //                      `ClientEqualsExecutor`, guarded twice, in
            //                      the factory and in the clone's initializer.
            //                      Two addresses of one man pass it, and no
            //                      further question is asked: no stake, no
            //                      history, no relation between the parties. So
            //                      the man who waited cannot be told apart from
            //                      the appellant's SECOND WALLET, and on the
            //                      silent road the deposit was crossing back
            //                      into the circle it left.
            //
            //                      ⚠️ AND THE NUMBER THAT BROKE THE CHOICE,
            //                      because the shape of the hole is not the
            //                      reason — the price is. Measured on commit
            //                      24920f45, one appeal on a pot of 20 000 000
            //                      base units, verdict left standing, nobody
            //                      answering: it cost a man whose counterparty
            //                      is somebody else 20 000 000, and it cost a
            //                      man holding both sides with two addresses
            //                      NOUGHT. Not "less" — nought. The owner's
            //                      rule of 10 October 2026, fourth clause: a
            //                      price that comes back to its buyer is not a
            //                      price. The deposit is the protocol's only
            //                      brake on challenging a verdict, so on that
            //                      road there was no brake at all.
            //   the treasury     — THIS, SINCE 19 OCTOBER 2026, and the reason
            //                      is the one property the other three cannot
            //                      offer: it CANNOT BE MANUFACTURED WITH A
            //                      SECOND KEY. Home, the bank and the other
            //                      side are each an address an attacker either
            //                      owns or can be drawn into owning; the
            //                      treasury slice is a protocol balance with no
            //                      private key behind it, pushed out to
            //                      `FactoryStorage.feeRecipient` by the open
            //                      `ArbiterVaultFacet.withdrawTreasurySlice`.
            //                      Whatever else it is, it is not the
            //                      appellant's other pocket at any number of
            //                      keys — so the 20 000 000 above is now the
            //                      cost of a silent appeal to everybody,
            //                      including the man who owns both sides.
            //
            //                      ⚠️ IT DOES NOT RESCUE THE WAITER, and that
            //                      is a cost of this choice rather than a
            //                      detail of it. The party who was held out of
            //                      his money for four days by an unread appeal
            //                      is compensated by nothing on this road. He
            //                      keeps what the answered road gives him (the
            //                      toll, below) and nothing here. The choice is
            //                      between paying a waiter who cannot be
            //                      distinguished from the attacker and paying
            //                      nobody; this branch pays nobody.
            //
            // ⚠️ IT USED TO BURN INTO THE BANK, THEN FOR ONE DRAFT TO GO HOME,
            // AND THEN FOR TWO DAYS TO CROSS TO THE OTHER SIDE. All three are
            // refused above, each with the reason it was refused for, and the
            // first two keep the reasons they always had: the case measured in
            // 24920f45 is an argument against the THIRD and says nothing for or
            // against those two.
            //
            // ⚠️ AND THE ADDRESSEE IS DERIVABLE FROM THE LOGS THIS SAME
            // TRANSACTION ALREADY WRITES, WHICH IS WHY NO EVENT WAS ADDED FOR
            // IT. `AppealDepositForfeited` fires on every road that leaves the
            // verdict standing, and `AppealPanelPaid` fires on exactly the
            // roads where somebody answered — it is emitted unconditionally in
            // the `else` of this very test. So forfeited AND no panel paid is
            // this branch and no other: an overturn emits no forfeiture, and an
            // answered road that left the verdict standing always emits the
            // panel's payment, even where the wage rounds to nought.
            // `AppealDepositToTheOtherSide` is absent here for the same reason,
            // and the AMOUNT is the third argument of the forfeiture. Measured
            // in test/AppealPriceReturnsToItsBuyer.t.sol, on both roads, so the
            // absence is read against a scene where the event does fire.
            toTreasury = deposit;
        } else {
            if (overturn) {
                // THE APPEAL WAS WON, SO THE DEPOSIT IS NOT A PRICE AND MUST NOT
                // BEHAVE LIKE ONE (the owner, 18 October 2026). It goes home whole,
                // below, and the panel is paid by the man whose mistake they
                // corrected — out of the case bond he put down to take the case.
                //
                // ⚠️ WHAT THIS UNDID, AND IT IS A SIMPLIFICATION RATHER THAN A
                // RESHUFFLE. Until today a right appellant came out at nought the
                // CLEVER way: the deposit was spent and the judge's bond came back
                // to him instead, so the two had to be EQUAL for the guarantee to
                // hold — and they stopped being equal the moment the bond was held
                // down to the deal's pot, leaving a winning appellant on a $1 pot
                // down nineteen dollars. A refund needs no such equality: he gets
                // back what he paid, on any pot, and the guarantee of decision 173
                // stops depending on two pricing functions agreeing.
                //
                // ⚠️ THE BOND NO LONGER REACHES THE APPELLANT AT ALL. He is whole
                // from the refund; handing him the bond on top would pay him for
                // somebody else's mistake, and a profit on winning an appeal is a
                // reason to manufacture one.
                //
                // ⚠️ THE BOND IS TAKEN HERE AND NOT IN THE `overturn` BLOCK AT THE
                // BOTTOM, where it used to live. The money of this settlement is
                // decided in ONE place now, because the remainder of its division
                // has to join `toOtherSide` before that single dispatch runs; the
                // judge's RECORD — the XP slash and the booked mistake — stays
                // below, where it belongs. Nothing between here and there touches
                // `caseBonds`, so the read is the same read.
                //
                // ⚠️ AND WHERE THE PANEL GETS NOTHING, NAMED RATHER THAN LEFT TO BE
                // FOUND: a case that carries NO bond. `caseBonds` has been written
                // since 22 September 2026 only, a pot of nought buys a bond of
                // nought, and `clearStuckVerdict` can remove the record — in all
                // three the pocket is nought and the men who read the case are
                // unpaid. The appellant is still made whole, which is the half of
                // the old gap this closes: yesterday such a verdict left HIM down
                // the whole deposit as well.
                //
                // ⚠️ AND THE QUARTER THAT LEAVES THIS POCKET GOES TO THE TREASURY,
                // which is the one addressee this road can have. The other three
                // were each refused on their own ground: the ARBITER BANK, because
                // the corps must not earn out of complaints about the corps; the
                // APPELLANT, because he is already whole from the refund and a
                // profit on winning an appeal is a reason to manufacture one; the
                // OTHER SIDE OF THE DEAL, because on this road the appellant was
                // RIGHT — the other side is the man whose win was wrong, and
                // paying him a quarter of the judge's bond for having been wrong
                // is a reward pointing exactly the wrong way.
                // ⚠️ AND SINCE 20 OCTOBER 2026 THE POCKET IS TWO SUMS, NOT ONE
                // (the owner, that day): the judge's case bond AND the dispute
                // fee he has just lost the right to. The fee has sat on this
                // diamond since the dispute was opened — `raiseDispute` pays it
                // at the door and `ArbiterVaultFacet.holdDisputeFee` holds it —
                // so it is money already here and needs no second transfer.
                //
                // WHY IT IS DIVIDED HERE AND NOT WHERE IT USED TO GO. Until
                // today a forfeited fee went to the arbiter BANK, from
                // `ArbiterVaultFacet._settleForfeitedShare`, and it got there
                // at `finalizeVerdict` — one call LATER than this one. Two
                // things follow from moving it here, and the second is the
                // reason:
                //
                //   * the panel's pay becomes blind to the outcome. 20 + 10 is
                //     30, which is what `appealDepositFor` charges for an
                //     appeal, so three quarters of this pocket is three
                //     quarters of that one. A man who reads a case earns the
                //     same whether he overturns the verdict or leaves it
                //     standing, and that is the whole reason the owner chose
                //     those three flat figures.
                //   * it joins ONE division instead of topping up a share
                //     already written. `voterShare` is written below and
                //     `withdrawAppealShare` is a pull with a per-arbiter
                //     taken-flag; money arriving after some men had pulled and
                //     others had not would pay them different wages for the
                //     same work, decided by who pressed first. There is no race
                //     to lose here because there is nothing to add later.
                //
                // ⚠️ AND THE OBJECTION OF 17 OCTOBER 2026 IS ANSWERED RATHER
                // THAN FORGOTTEN. That day this money was taken OFF the panel
                // precisely because paying the men who voted to overturn made
                // the overturn itself profitable — the price of clearing an
                // honest arbiter out of the corps was measured at NEGATIVE
                // $31.81, the attacker was paid to do it. What made it a bias
                // was that the panel got this money ONLY on an overturn. It no
                // longer does: the two pockets are equal, so nothing about a
                // panel's earnings points at an overturn, and the forfeit falls
                // where the work was done.
                ArbiterRegistryStorage.CaseBond storage cb = d.caseBonds[agreement];
                uint256 bond = cb.amount;
                if (bond != 0) {
                    cb.amount = 0;
                    // ⚠️ THE EVENT KEEPS ITS NAME AND THE NAME IS STILL TRUE OF
                    // HIM: he forfeits it, whole, and the log never carried the
                    // destination. See the paragraph on it in the docstring.
                    //
                    // ⚠️ AND IT CARRIES THE BOND AND NOT THE POCKET, WHICH IS A
                    // CHANGE OF 20 OCTOBER 2026 THAT A READER MUST NOT MISS.
                    // Until today the two were the same number and this log was
                    // how the toll was derived — `amount - perVoter * voters`
                    // off this event and `AppealPanelPaid`. The pocket now also
                    // holds the forfeited dispute fee, so that subtraction
                    // needs BOTH logs: this one and `DisputeFeeToThePanel`. The
                    // alternative was to widen this event's amount to the whole
                    // pocket, which would have made a log named after the bond
                    // say something else — and silently, to every reader
                    // outside this repository who already decodes it.
                    emit ArbiterRegistryFacet.CaseBondForfeited(agreement, v.arbiter, bond);
                }
                pocket = bond;
                uint256 forfeitedFee = d.disputeFeeHeld[agreement];
                if (forfeitedFee != 0) {
                    // Zeroed HERE, which is what keeps `settleDisputeFee` from
                    // paying it a second time when `finalizeVerdict` runs: that
                    // door returns in silence on a nought amount, and the
                    // marker beside it (`disputeFeePrepaidBy`) is deliberately
                    // left standing so the deal is still known to have prepaid.
                    d.disputeFeeHeld[agreement] = 0;
                    pocket += forfeitedFee;
                    emit ArbiterRegistryFacet.DisputeFeeToThePanel(agreement, v.arbiter, forfeitedFee);
                }
            } else {
                // THE VERDICT STANDS AND SOMEBODY READ THE CASE, so the appellant's
                // deposit is the pocket (the owner, 18 October 2026) and three
                // quarters of it is the panel's wage (the owner, 19 October 2026).
                // A vote to overturn or a reading that asks for none count the
                // same, because the wage is for the work and not for its outcome.
                // A wage payable only for an overturn is a wage FOR overturning,
                // the bias decisions 175 and 176 both named and both left standing
                // as a gate on this cut.
                //
                // ⚠️ THE QUARTER THAT LEAVES THIS POCKET CROSSES TO THE OTHER SIDE
                // OF THE DEAL, and the argument is the one the half of 17 October
                // never had: the man who gets it WAITED. He won the verdict and was
                // held out of his money by an appeal that did not carry. The half
                // was refused because it charged a RIGHT appellant too; this road
                // is the one the appellant lost, and SINCE 19 OCTOBER 2026 IT IS
                // THE ONLY ROAD ON WHICH ANYTHING CROSSES AT ALL — the silent
                // road's whole deposit used to cross here too and now goes to
                // the treasury.
                //
                // ⚠️ NOT THE TREASURY HERE, THOUGH THE OTHER TWO ROADS BOTH END
                // THERE. The treasury takes the toll when the other side of the
                // deal is the man who was WRONG (the overturn), and it takes the
                // whole deposit when NOBODY ANSWERED, because the waiter cannot
                // then be told apart from the appellant's second address. Here
                // somebody answered AND the man who waited was right, which is
                // the combination the owner left alone on 19 October 2026.
                //
                // ⚠️ AND IT IS LEFT ALONE WITH ITS PRICE KNOWN, not because the
                // objection does not reach it. It does reach it: a man holding
                // both sides gets this quarter back too, so the same appeal on a
                // pot of 20 000 000 base units cost him 15 000 000 where it cost
                // a stranger 20 000 000 (commit 24920f45,
                // test/AppealPriceReturnsToItsBuyer.t.sol). The difference from
                // the silent road is the one the owner acted on: there the brake
                // was NOUGHT, here it is three quarters of it, because the wage
                // is owed to men the lot drew and a man who holds both SIDES of
                // the deal holds none of those seats. ⚠️ THAT LAST CLAUSE IS
                // ABOUT THE TWO-ADDRESS DEAL AND NOT ABOUT A SELF-SEATED PANEL,
                // which is a different attack priced separately above. Narrowing
                // this road is a separate decision and has not been taken.
                pocket = deposit;
            }

            // ⚠️ NO LOOP AND NO TRANSFER TO THE PANEL HERE. One number is
            // written for all of them and each man pulls his own with
            // `ArbiterVaultFacet.withdrawAppealShare`, keyed on the same
            // `hasVotedAppeal` both doors set. A payout per answerer inside
            // this call would give the one door that unfreezes an escrow a cost
            // that grows with turnout, and the day it ran out of gas the escrow
            // would be frozen for good.
            //
            // ⚠️ THE TOLL IS WHAT THE DIVISION DID NOT PAY OUT, AND IT IS ONE
            // SUBTRACTION RATHER THAN TWO ROUNDED FRACTIONS. That is the whole
            // of how "not one base unit gets stuck" is made true instead of
            // argued: the quarter, the base units the three-quarter fraction
            // truncated, and the base units the division among the answerers
            // could not split are ONE number, taken as `pocket` less what was
            // actually booked for the men. A second fraction computed for the
            // toll would leave a gap wherever both roundings fell the same way,
            // and that gap would be money no claim covers —
            // `_assertDiamondBalances` in the money scenes would be right to
            // call it a leak.
            //
            // So the identity holds by construction on both roads, to the base
            // unit: `each * answered + toll == pocket`.
            //
            // ⚠️ AND IT NEVER GOES TO THE APPELLANT ON THE REFUND BRANCH, which
            // would be the tidier line and would break the one equality this
            // rule exists for: a right appellant comes out at EXACTLY nought,
            // not at nought plus a quarter of somebody else's bond.
            //
            // `answered` cannot be nought here: it is nought exactly when
            // `_nobodyAnswered` is true, which is the branch this one excludes.
            //
            // ⚠️ AND THE WAGE CAN BE NOUGHT WITHOUT THE POCKET BEING NOUGHT,
            // which is the dust pot named at the constants above: a price of one
            // base unit has `1 * 3 / 4 == 0`, so `voterShare` is written as
            // nought, `getAppealShareOwed` answers nought, nobody holds a claim
            // against money nobody put down — and the single base unit leaves as
            // the toll, because the subtraction below cannot lose it.
            uint256 wage = pocket * APPEAL_WAGE_NUMERATOR / APPEAL_WAGE_DENOMINATOR;
            uint256 each = wage / answered;
            // uint64 cannot truncate. `each <= wage <= pocket`, and `pocket` is
            // either the deposit (`appealDepositFor`) or a case bond
            // (`caseBondFor`, which is that same number held down to the pot) —
            // so either way at most APPEAL_DEPOSIT_CAP (2e8). The multiplication
            // by three cannot overflow for the same reason. ⚠️ THE BOUND DOES
            // NOT NEED THE TWO TO BE EQUAL, and they stopped being equal below
            // a 20 USDC pot on 20 October 2026: it needs only that neither can
            // exceed the cap, and the ceiling only ever lowers one of them.
            d.appealLedgers[agreement].voterShare = uint64(each);
            uint256 toll = pocket - each * answered;
            if (overturn) {
                toTreasury = toll;
            } else {
                toOtherSide += toll;
            }
            emit ArbiterRegistryFacet.AppealPanelPaid(agreement, each, answered, 0);
        }

        if (overturn) {
            // ⚠️ THE DEPOSIT GOES HOME WHOLE AND NO LOG SAYS HE LOST IT. That
            // is the point of this branch existing at all rather than a `!= 0`
            // guard: `AppealDepositForfeited` used to fire OUTSIDE the if/else
            // on the whole deposit in every branch, and on this road it would
            // be a log asserting a loss the chain did not take. It is not
            // replaced by an event of its own — `AppealDepositReturned` was
            // declared, retired on 18 October 2026 and deleted from the ABI
            // census and the browser's side together, and re-declaring it to
            // carry a fact that is already derivable would move a seam three
            // readers outside this repository decode. The fact IS derivable:
            // the refund happens on exactly the overturn branch, so
            // `AppealResolved(agreement, appellant, true)` in this same
            // transaction says the deposit went home, and the amount is what
            // `AppealRaised` cost him.
            //
            // SOFT, like every push on this path: these writes are what
            // unfreeze the verdict, and a transfer that reverts must not take
            // them down with it.
            _paySoft(d, usdc, agreement, v.appellant, deposit);
        } else {
            // ⚠️ HE LOSES THE WHOLE DEPOSIT ON BOTH ROADS THAT LEAVE THE
            // VERDICT STANDING, so the event fires on both and carries the
            // whole of it. Only the loser pays, and from today "the loser"
            // means the man whose appeal did not carry — where until today it
            // meant every appellant who ever raised one.
            emit ArbiterRegistryFacet.AppealDepositForfeited(agreement, v.appellant, deposit);
        }

        if (toOtherSide != 0) {
            if (otherSide != address(0)) {
                // SOFT, like every push on this path: these writes are what
                // unfreeze the verdict, and a transfer that reverts must not
                // take them down with it.
                _paySoft(d, usdc, agreement, otherSide, toOtherSide);
                emit ArbiterRegistryFacet.AppealDepositToTheOtherSide(agreement, otherSide, toOtherSide);
            } else {
                // ⚠️ NO OTHER SIDE TO PAY, AND THE ONLY WAY TO GET HERE IS AN
                // AGREEMENT THE REGISTRY NEVER RECORDED — a contract somebody
                // manufactured that answers the handful of signatures
                // `claimDispute`, `submitVerdict` and `raiseAppeal` ask it for.
                // The parties are read from the REGISTRY and not from that
                // contract on purpose: reading them from the thing under
                // measurement would hand the deposit to whatever address its
                // maker nominated, which is the free junk appeal again wearing
                // a different hat. It goes where money with no owner goes in
                // this protocol, and the cost of the hole falls on whoever
                // manufactured it.
                //
                // ⚠️ AND SINCE 19 OCTOBER 2026 NOTHING IS KNOWN TO REACH THIS
                // LINE. It is kept anyway, deliberately, and the two halves of
                // that have to be read together.
                //
                // Why nothing reaches it: `toOtherSide` is now written in ONE
                // place only — the toll, in the branch where somebody answered
                // — because the silent road credits the treasury instead.
                // Answering requires a record: both doors, `voteToOverturn` and
                // `replyNoOverturn`, go through `_admitAnswerer`, which refuses
                // an unrecorded agreement with `NotRegisteredAgreement`. So a
                // non-zero `toOtherSide` implies a record, a record implies
                // `_theOtherSide` found one, and it answers the zero address on
                // a record it found only if the appellant is neither party —
                // which `raiseAppeal` already refuses with `NotLosingParty`,
                // reading the parties off the clone, whose `client` and
                // `executor` are written once in `initialize` and never again.
                // The outer `if (toOtherSide != 0)` is what makes this an
                // argument about one variable rather than about the whole
                // settlement.
                //
                // Why it is kept: that is an argument across four functions and
                // two contracts, and every link in it is a line somebody may
                // edit for a reason that has nothing to do with this one. A
                // guard that was removed because the reasoning said it could
                // not fire is how holes open; if a later change puts a second
                // write into `toOtherSide`, or lets an answer through on an
                // unrecorded deal, this line is the difference between money
                // with no owner landing in the bank and `_paySoft` pushing a
                // deposit at the zero address. Unreachable is a measurement of
                // today's tree, not a property of the code.
                //
                // Measured rather than argued, in test/AppealPanelWage.t.sol:
                // `test_AManufacturedAgreementTakesTheSilentRoadToTheTreasuryAndItCostsItsMakerTheLot`
                // drives a manufactured agreement at this settlement and
                // asserts the bank does not move — the deposit lands in
                // `treasurySlice` instead. ⚠️ IT IS GREEN, AND THIS PARAGRAPH
                // NAMED IT BY A DEAD NAME AND CALLED IT RED. The scene was
                // `...IsTheOneRoadToTheBankAndItCostsItsMakerTheLot` while it
                // drove this line as the live road; on 19 October 2026 it was
                // renamed and retargeted to measure the closure POSITIVELY. A
                // lock named by a dead name dies in silence, and a paragraph
                // that expects a red teaches the next reader to ignore one.
                d.vaultBalance += toOtherSide;
            }
        }

        // THE TOLL ON AN OVERTURN, AND IT IS A CREDIT RATHER THAN A TRANSFER.
        // `treasurySlice` is pushed out to `FactoryStorage.feeRecipient` by the
        // open `ArbiterVaultFacet.withdrawTreasurySlice`, which anybody may
        // press; the money does not stand still and needs no door of its own.
        // Credited and not transferred for the same reason the dispute fee's own
        // slice is: a fee recipient that cannot receive — a blacklisted address,
        // a contract that reverts — would otherwise hold up THIS call, and this
        // call is what unfreezes the escrow.
        //
        // ⚠️ TWO ROADS REACH IT AND THEY CARRY DIFFERENT MONEY, which is the
        // one thing to hold on to here since 19 October 2026. The sentence that
        // stood in this place read "IT IS REACHED ON THE OVERTURN ROAD ONLY",
        // and it stopped being true the moment the silent road's deposit was
        // sent here. What arrives now:
        //
        //   the overturn    — the TOLL, the remainder of the division of the
        //                     overturned judge's bond.
        //   silence         — the WHOLE DEPOSIT, for the reasons written out at
        //                     the `_nobodyAnswered` branch above.
        //
        // The third road — answered, verdict standing — sends its toll to the
        // other side instead, so a reader comparing the branches still sees no
        // symmetry and should still not add any.
        if (toTreasury != 0) d.treasurySlice += toTreasury;

        if (overturn) {
            address slashedArbiter = v.arbiter;

            // ⚠️ THE READ OF `overturned` THAT STOOD HERE IS GONE WITH THE
            // BRANCH IT FED (9 October 2026). It existed to tell "the panel is
            // correcting the HAND" from "the panel is correcting the ARBITER",
            // and after the hand was removed there is only the second. The
            // paragraph that used to stand here reasoned about TWO writers of
            // the flag; there is one now, and the reasoning would be false.

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
            // ⚠️ THE VINDICATION BRANCH STOOD HERE AND IS GONE (9 October 2026).
            //
            // It handled one state and one only: THE HAND HAD ALREADY OVERTURNED
            // THIS VERDICT, and the panel was now flipping the outcome back to
            // the arbiter's own ruling. It took one overturn back off his
            // record, set `verdictVindicated`, withdrew the chain's own
            // accusation and restored the streak -- a counterweight to the
            // owner's mistake, and nothing else.
            //
            // ⚠️ THE STATE IS NOW UNREACHABLE BY CONSTRUCTION, not by care.
            // `v.overturned` has exactly ONE writer left, and it is the line a
            // few above this one, inside this same function. The flag was read
            // at the TOP of this branch, before that write; one appeal exists
            // per verdict (`appealResolved` above), so this branch cannot see
            // its own write. With the hand gone there is no other writer, so
            // "already overturned when the panel sat down" cannot happen.
            // Guarded mechanically rather than by this paragraph:
            // test/ArbiterOverturnedHasOneWriter.t.sol counts the writers in
            // src/ and demands exactly one, inside `resolveAppeal`.
            //
            // ⚠️ WHAT IS DELIBERATELY KEPT, THOUGH NOTHING WRITES IT ANY MORE:
            // the `verdictVindicated` mapping (this namespace is append-only, a
            // field is never taken back out) and its read in `finalizeVerdict`.
            // With no writer it answers false for every deal, which makes
            // `countAsOverturn` equal to `v.overturned` -- the same arithmetic,
            // one SLOAD. Deals vindicated BEFORE this cut keep their bit and are
            // still read correctly, which is the reason the read stays rather
            // than being simplified away.
            {
                ReputationStorage.Data storage rep = ReputationStorage.data();
                _slashArbiterXP(rep, slashedArbiter);
                // `by` is zero: anyone may call resolveAppeal, and the VOTES decide.
                // Naming whoever pressed "settle" as the author would be the worst
                // of the three possible untruths.
                ArbiterRegistryStorage.recordArbiterMistake(
                    d, rep, slashedArbiter, address(0),
                    ArbiterRegistryFacet.DemotionPath.AppealVote, agreement
                );
            }

            // ⚠️ THE BOND IS NOT HANDLED HERE ANY MORE, AND THIS PARAGRAPH IS
            // WHERE A READER WILL COME LOOKING FOR IT. Until 18 October 2026
            // this block took the bond and handed it to the APPELLANT; both
            // halves of that are gone. It is now the PANEL'S WAGE and it is
            // taken in the money block above, where the remainder of its
            // division can join the one dispatch to the other side. What is
            // left here is the judge's RECORD and nothing else.
            //
            // ⚠️ WHAT THE MOVE GAVE UP, SAID PLAINLY: the sentence "the whole
            // of the bond leaves the judge" is unchanged, and so is his loss —
            // bond at the settlement, 90% share at the finalization. Only the
            // addressee moved, from the appellant to the men who read his case.
            //
            // ⚠️ AND WHAT IT GAVE: a right appellant no longer depends on two
            // pricing functions agreeing. He comes out at nought by being
            // REFUNDED what he paid, so the "$19 short on a $1 pot" the
            // pot-measured bond opened on 18 October closes the same evening it
            // opened — argued in the refund branch above. ⚠️ THERE ARE TWO
            // PRICING FUNCTIONS AGAIN (20 October 2026), and this is the line
            // that stops that mattering: `appealDepositFor` sizes what he paid
            // and `caseBondFor` sizes the panel's pocket, they differ below a
            // 20 USDC pot, and his refund reads neither of them — it reads
            // `_depositOf`, the receipt of what he actually put down.
            //
            // THE RECORD IS LEFT STANDING WITH A ZERO AMOUNT rather than
            // deleted, and that is still true of the write above.
            // `_releaseCaseBond` runs inside `finalizeVerdict` for every verdict
            // and returns at once on a zero, and `cb.arbiter` is what
            // `_settleForfeitedShare` checks before it hands anything back; a
            // deleted record would make that check read a zero address and send
            // money to the bank for a reason that is not true.
            //
            // ⚠️ THE EVENT KEEPS ITS NAME, AND THE NAME IS STILL TRUE OF HIM.
            // `CaseBondForfeited` is what happens to the JUDGE — he forfeits it,
            // whole — and the log carries his address and the amount, never the
            // destination. Renaming it would move a seam the browser's ABI and
            // two relay tables all read, for a fact the log never stated. Where
            // the money went is now `AppealPanelPaid` in the same transaction,
            // whose `perVoter` is the bond divided by the men who answered.
        }

        emit ArbiterRegistryFacet.AppealResolved(agreement, v.appellant, overturn);
    }

    /// Money to a party, SOFT. For a heavier reason than in
    /// clearDisputeClaim: the writes in resolveAppeal are what unfreeze the
    /// verdict; a reverting refund takes them down with it, and every other
    /// door out is already shut (finalizeVerdict: VerdictFrozenError,
    /// unfreezeVerdict and overturnVerdict: AppealInProgress, raiseAppeal:
    /// AlreadyAppealed, Agreement.triggerArbiterTimeout: VerdictInFlight,
    /// forever, because hasSubmittedVerdict never goes back to false). A
    /// deposit that cannot be delivered would therefore strand the WHOLE
    /// escrow, in the clone, where no rescue function exists. What does not
    /// land goes into the existing claimable — real USDC stays on the diamond,
    /// so the booking is backed.
    function _paySoft(
        ArbiterRegistryStorage.Data storage d,
        address usdc,
        address agreement,
        address who,
        uint256 amount
    ) private {
        if (!ArbiterRegistryStorage.softTransfer(usdc, who, amount)) {
            d.refundableBounty[who] += amount;
            emit ArbiterRegistryFacet.DisputeBountyRefundable(agreement, who, amount);
        }
    }

    /// WHICH PARTY TO THE DEAL DID NOT RAISE THIS APPEAL — the addressee of the
    /// WHOLE deposit when nobody read the appeal, and of the TOLL, a quarter of
    /// it, when somebody read it and the verdict stood (19 October 2026, the
    /// owner). ⚠️ IT SAID "half the deposit" until the evening of 18 October,
    /// when the owner removed the half that crossed on every outcome, and then
    /// "the division's remainder" for a day, when the whole pocket was the
    /// panel's wage and only the base units it could not split crossed. The
    /// quarter is neither: it is charged on ONE outcome, like the remainder, and
    /// it is a real number rather than dust, like the half.
    ///
    /// ⚠️ READ OUT OF THE REGISTRY'S RECORD AND NEVER OUT OF THE AGREEMENT
    /// ITSELF. `raiseAppeal` staticcalls the clone to ask whether the caller is
    /// a party, which is the right question THERE: it is about letting a man
    /// in. Here the question is where to send money, and a manufactured
    /// contract would answer it with whatever address its maker chose — which
    /// would hand the deposit straight back to him. The registry's record is
    /// written once at registration (`RegistryFacet._register`) and nobody can
    /// forge it.
    ///
    /// Answers the zero address when the registry holds no record of the deal,
    /// and when the appellant is neither of the two parties it does hold. The
    /// caller sends that money to the bank and says why.
    function _theOtherSide(address agreement, address appellant)
        private view returns (address)
    {
        RegistryStorage.AgreementRecord storage rec = RegistryStorage.store().agreements[agreement];
        if (rec.agreement != agreement) return address(0);
        if (appellant == rec.client)   return rec.executor;
        if (appellant == rec.executor) return rec.client;
        return address(0);
    }
}
