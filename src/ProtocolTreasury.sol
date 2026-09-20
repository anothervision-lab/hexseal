// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ProtocolTreasury.sol
//
// The treasury that replaces the one deployed at
// 0x2e7a7A0515bfDC0006A812EBb3E55d32800Bc660 (src/Treasury.sol, still in the
// tree so its bytecode stays verifiable against its own source — that is how
// OPEN-ITEMS item 151 was settled, and the old file must not be edited for it).
//
// WHY A NEW CONTRACT AT ALL, when the old one is not broken. Because the old
// one froze GUESSES. Its DAO threshold, its 500 USDC vault target and its
// 70/30 split were chosen by judgement, never by measurement, and it has no
// administrator and no diamond cut — a wrong number there is fixed only by
// replacing the contract, and replacing it costs the accumulated reserve.
// Decision 65 splits the problem in two:
//
//   * the SHAPE freezes forever — the order of the ladder, who may receive
//     money at all, and the bounds no number may cross;
//   * the NUMBERS are read off the diamond and are changed by a diamond cut,
//     with no new contract and no lost reserve.
//
// The point of this file is to be the LAST treasury. Everything that could
// later turn out to be a wrong number is read; everything that could later
// turn out to be a wrong promise is frozen.
//
// THERE IS STILL NO ADMINISTRATOR. Not one owner-only function, not one
// setter. What the diamond owner can do is move the numbers this contract
// READS, and every one of those is clamped by a frozen bound in the direction
// that costs him — see "THE CLAMPS" below.
//
// ------------------------------------------------------------
// WHAT FREEZES (decision 65)
//
// 1. THE ORDER OF THE LADDER: vault shortfall → arbiter payroll → foundation
//    → the remainder to the reserve. The order is the promise.
//
// 2. THE RECIPIENTS. The foundation address is immutable and there is no
//    function to name another one. The vault and the payroll can only be paid
//    into the diamond. The reserve can only leave to the address the diamond
//    names as the DAO.
//
// 3. THE CLAMPS. Every readable number is squeezed by a frozen bound, and the
//    direction of each bound is chosen so that moving the number can never pay
//    the person able to move it:
//
//      foundation share  — a CEILING, and the only one of the four that
//                          MOVES: FOUNDATION_BPS_MAX while the owner still
//                          governs, FOUNDATION_BPS_MAX_DAO once governance has
//                          been handed over, chosen by the diamond's own
//                          isDaoActive() and then REMEMBERED HERE FOREVER
//                          (daoLatched). The owner may lower his own share any
//                          day and can never raise it past whichever of the two
//                          is in force. Why the handover moves the CEILING and
//                          not the VALUE is argued at foundationBpsCeiling();
//                          why the answer is latched rather than re-read is
//                          argued at daoLatched.
//      vault share       — a CEILING (VAULT_BPS_MAX).
//      payroll share     — a CEILING (PAYROLL_BPS_MAX).
//      vault target      — a CEILING (VAULT_TARGET_MAX). Without it the owner
//                          would set the vault to a billion and the whole
//                          income would run into the arbiter bank past the
//                          reserve.
//      DAO threshold     — DELIBERATELY UNBOUNDED, and this is decision 65
//                          exactly: the ceilings are frozen, the threshold
//                          is not. A
//                          floor under the threshold would be the one clamp
//                          that can LOCK money rather than protect it (a floor
//                          set above what the protocol ever reaches freezes the
//                          reserve for good), and the gate it would harden is
//                          already decorative: the same owner reaches the same
//                          result by three live paths, the cheapest measured at
//                          31 717 gas and invisible in the loupe. Those three
//                          are listed in the header of src/Treasury.sol and are
//                          not repeated here; nothing about them changed.
//
//    ⚠️ The three share ceilings are ONE decision, not three. They are shares
//    of the same base, so what they leave over is the reserve's guaranteed
//    floor:
//
//        RESERVE_BPS_MIN = 10 000 − (FOUNDATION_BPS_MAX + VAULT_BPS_MAX
//                                    + PAYROLL_BPS_MAX)
//
//    RESERVE_BPS_MIN below is that subtraction written out, so raising any one
//    of the three is visibly taking the difference out of the reserve. Today it
//    is 10 000 − (6 000 + 1 000 + 2 000) = 1 000: a tenth of all income the
//    reserve keeps whatever the readable numbers say. The compiler refuses this
//    file if the three ever sum ABOVE 100%, and a runtime lock
//    (test_TheThreeCeilingsLeaveTheReserveATenthAndThatIsItsFloor) refuses them
//    reaching it — at exactly 10 000 the file still compiles and the floor is
//    silently gone, which is the state the owner ended on 4 September 2026.
//
// 4. THE DIRECTION OF DEGRADATION: a read that does not come back is answered
//    with the value that favours the PROTOCOL, never the foundation. The old
//    treasury already did this in one place (foundationBps pinned the smaller,
//    post-DAO share on a failed read); here it is the rule for all of them.
//    Concretely: an unreadable vault share, payroll share or vault target all
//    read as ZERO, and the money they would have taken falls through to the
//    reserve; an unreadable foundation share reads as FOUNDATION_BPS_UNREAD,
//    which is a floor, not a default; and an unreadable isDaoActive() picks the
//    STRICTER of the two foundation ceilings, i.e. the contract assumes
//    governance has already been handed over rather than that it has not.
//
//    The reason the foundation is the one measured against is not suspicion of
//    a particular person: today the foundation address and the diamond owner
//    are the same party, so "the foundation gains" and "the key holder gains"
//    are the same sentence. If they ever stop being the same party the rule
//    still costs nothing.
//
// ------------------------------------------------------------
// WHAT THE DIAMOND MUST MOUNT — READ THIS BEFORE DEPLOYING
//
// ⚠️ SIX selectors this contract calls DO NOT EXIST on the diamond as of
// 4 September 2026 (checked against 0x760F07367888C62f7c2Dfb619A5e534132855ce5
// on Base Sepolia, not against a document):
//
//     getVaultTarget()               — the vault's target, in USDC. Decision 60
//                                      wants that target expressed as a NUMBER
//                                      OF DISPUTES rather than a dollar sum;
//                                      the multiplication belongs on the
//                                      diamond side, because what one dispute
//                                      costs is arbitration business logic and
//                                      the treasury must not pretend to know it.
//     getTreasuryVaultBps()          — the vault's share of income.
//     getTreasuryPayrollBps()        — the arbiter payroll's share of income.
//     getTreasuryFoundationBps()     — the foundation's share of income.
//     fundArbiterPayroll(uint256)    — where the payroll stream is paid in.
//     getArbiterPayrollBalance()     — the payroll pot, so a push can check it
//                                      actually grew.
//
// Five more ARE mounted, and were read off the live chain on 4 September 2026
// rather than out of a document: getVaultBalance() = 17 428 500,
// getDaoThreshold() = 10 000, getUniqueActiveUsers() = 2, getDAOAddress(), and
// isDaoActive() = false (routed to facet 0x508a708c39Aa3Fc13EA994DFafcc5AbC683ab04d).
//
// ⚠️ ORDER OF ROLLOUT. Mount the six FIRST, install this treasury with
// setFeeRecipient SECOND. In the other order every distribute() in between runs
// fully degraded: the vault gets nothing, the payroll gets nothing, the
// foundation gets FOUNDATION_BPS_UNREAD and the whole rest piles into the
// reserve. Nothing is lost and nothing is stuck — but money laddered under the
// degraded rule is NOT re-laddered afterwards, and there is no function that
// could move it back. This is the one operational mistake this design makes
// cheap to commit and impossible to undo.
//
// ------------------------------------------------------------
// THE ONE STRUCTURAL CHANGE AGAINST THE OLD TREASURY: THE LADDER NO LONGER
// WRITES TO THE DIAMOND
//
// In the old treasury distribute() funded the vault inside itself, with a raw
// call(gas(), ...). That single line is OPEN-ITEMS item 115, and it was
// measured on 4 September 2026 against a facet that expands memory instead of
// answering: honest distribute() costs 128 033 gas, and against the burner it
// DIES at a 200 000-300 000 budget and eats 4 929 085 of a five-million one.
// The header of the old treasury promises that a failure of the vault step
// "must not bring down steps 2 and 3"; that promise holds against a REVERTING
// fundVault and does not hold against one that burns gas.
//
// Here the ladder does not write to the diamond at all. distribute() only
// moves numbers between four pots inside this contract; the money leaves for
// the diamond later, through pushVault() and pushPayroll(), which are separate,
// permissionless and retryable. Three things follow, and they are the reason
// this is a shape change and not a tidy-up:
//
//   * A gas-burning facet cannot touch the distribution any more. Not "cannot
//     easily" — it is not on the path. This is what item 115 asked for, and no
//     frozen gas number had to be guessed to get it.
//
//   * The push may now be STRICT. The old distribute() had to tolerate a
//     silent vault failure, because reverting there would wall up the whole
//     ladder — and the price was measured and written down: ten 200 USDC
//     batches went into a broken fundVault, all 2000 USDC vanished, and every
//     call still emitted a successful-looking event. Here a push that does not
//     end with the vault visibly larger reverts, and the money simply stays
//     owed. Nothing is ever silently eaten.
//
//   * The DistributeFirst gate is gone, and with it the "1 wei of dust walls up
//     topUpVault() forever" hole and the permanent constraint it imposed on the
//     diamond ("fundVault must never refuse because of the SIZE of an amount,
//     for as long as this treasury lives"). That gate existed for one reason:
//     with the old nested arithmetic, calling topUpVault() before distribute()
//     moved real money from the reserve to the foundation — 210 USDC per round,
//     measured. Under the flat shares below the foundation's take is
//     foundationBps × pending and depends on nothing else, so the two calls
//     commute. That is asserted, not asserted-and-hoped: see the
//     order-independence test.
//
// WHY THE PUSH IS NOT GAS-CAPPED, and why that is now an argument rather than
// an omission. The honest cost was measured on a fork of Base Sepolia against
// the REAL USDC (0x036CbD53842c5426634e7929541eC2318f3dCF7e, a proxied
// FiatTokenV2_2, dearer than any mock) and the REAL diamond — the number is in
// script/protocol-treasury-call-gas.allow. A frozen ceiling was still rejected,
// because on an immutable contract a ceiling that is one day too low locks
// legitimate vault funding FOREVER, and what fundVault does inside is the
// diamond's business and is allowed to grow. The caller already holds a cap
// that an immutable constant cannot hold: the gas limit of his own
// transaction. Since the push is a standalone, retryable call whose failure
// costs nobody but its voluntary caller, that is the right place for the limit
// — it can be lowered the day a hostile facet appears, and a constant cannot.
//
// ------------------------------------------------------------
// WHAT THIS CONTRACT STILL DOES NOT PROTECT AGAINST — said out loud
//
// * THE RESERVE IS NOT SAFE FROM THE DIAMOND OWNER. It never was. The DAO gate
//   reads a counter and a threshold out of an upgradeable contract, so the
//   treasury cannot be stricter than the owner of that contract. Making the
//   threshold readable does not weaken this; it stops pretending. The real
//   protection is a timelock, and it is deliberately postponed (mainnet order
//   of work: wallet and timelock last).
//
//   ⚠️ ONE READ IS NO LONGER IN THAT SENTENCE, and it is the only one: the
//   handover flag. Once this contract has seen isDaoActive() answer true it
//   remembers it in its own storage, so a later diamondCut cannot lift the
//   foundation's ceiling back up. It is the only read whose answer is worth
//   remembering, because activateDAO() is the only one the diamond itself
//   treats as irreversible — see daoLatched. Every OTHER number here is still
//   re-read every time and is still the owner's to move.
//
// * THE VAULT AND THE PAYROLL POTS LIVE IN THE DIAMOND. Once pushed, they are
//   under the same key. The clamps bound how fast income can be moved there,
//   not what happens to it afterwards.
//
// * MONEY OVER THE VAULT TARGET STILL HAS NOWHERE TO GO but the reserve, and
//   the reserve has one pre-DAO exit (topUpVault). That is decision 64's "70%
//   in suspense", and it is a question about what the protocol is for, not a
//   defect of this file.
//
// * ⚠️ THE PAYROLL POT IS THE ONE DEBT WITH NO CEILING. vaultOwed cannot exceed
//   the vault target, because vaultRoom() counts it — so a vault that stops
//   accepting money strands at most one target's worth, and the ladder keeps
//   running. payrollOwed has no target by construction (decision 69 gives the
//   stream none), so if getTreasuryPayrollBps() keeps answering while
//   fundArbiterPayroll() stops accepting, the payroll debt grows without bound
//   and its only exit is a facet that works again.
//
//   What holds today: the two selectors are mounted and removed together, and
//   an UNREADABLE share stops the accrual dead — which is why the payroll share
//   degrades to zero rather than to its ceiling. What is NOT held: a facet that
//   answers the view and refuses the funding. Nothing is lost in that state and
//   the money stays here, but it stops moving, and no function in this contract
//   can redirect it. Naming it rather than pretending otherwise: the shape that
//   would fix it is a target on the payroll too, and decision 69 has not asked
//   for one.
// ============================================================

interface IUSDC {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IHexsealDiamond {
    // -- writes --
    function fundVault(uint256 amount) external;
    function fundArbiterPayroll(uint256 amount) external;

    // -- reads --
    function getVaultBalance() external view returns (uint256);
    function getArbiterPayrollBalance() external view returns (uint256);
    function getVaultTarget() external view returns (uint256);
    function getTreasuryVaultBps() external view returns (uint256);
    function getTreasuryPayrollBps() external view returns (uint256);
    function getTreasuryFoundationBps() external view returns (uint256);
    function getDaoThreshold() external view returns (uint256);
    function getUniqueActiveUsers() external view returns (uint256);
    function getDAOAddress() external view returns (address);
    function isDaoActive() external view returns (bool);
}

contract ProtocolTreasury {

    // ==========================================================
    //  FROZEN NUMBERS
    // ==========================================================

    uint256 private constant BPS = 10_000;

    // THE SIX NUMBERS BELOW WERE APPROVED BY THE OWNER ON 4 SEPTEMBER 2026.
    //
    //     FOUNDATION_BPS_MAX      6 000   ceiling on the foundation's share
    //                                     while the owner still governs
    //     FOUNDATION_BPS_MAX_DAO  2 000   the same ceiling after the handover
    //     VAULT_BPS_MAX           1 000   ceiling on the vault's share
    //     PAYROLL_BPS_MAX         2 000   ceiling on the payroll's share
    //     VAULT_TARGET_MAX       50 000 USDC   ceiling on the vault target
    //     FOUNDATION_BPS_UNREAD   2 000   the foundation's share when unreadable
    //
    // They are the whole of what this contract can never take back. Four of
    // them were proposed by the executor and taken as they stood; the fifth,
    // FOUNDATION_BPS_MAX, the owner moved down from 7 000, and the sixth is new.
    // Each still carries the cost of being wrong in EITHER direction, stated
    // where it is declared, because that is what a reader replacing this
    // contract one day will need.
    //
    // ⚠️ THE FIRST THREE CEILINGS ARE ONE DECISION, NOT THREE — and 6 000 is
    // that decision, not a view about what a foundation deserves. They are
    // shares of the same base, so what they leave over is the reserve's
    // guaranteed floor:
    //
    //     RESERVE_BPS_MIN = 10 000 − (6 000 + 1 000 + 2 000) = 1 000
    //
    // At the 7 000 originally proposed the three summed to exactly 10 000 and
    // the reserve had NO floor at all: every cent of protocol income could
    // lawfully be routed past it. The owner's instruction was to bring it down
    // to 6 000, because otherwise the distribution does not work at all.
    // Whoever raises any one of the three next
    // is eating that tenth, and RESERVE_BPS_MIN is written as a subtraction so
    // that he cannot do it without seeing what he is eating.
    //
    // TODO(owner): one question of SHAPE is open too, and it is not a number.
    // The payroll stream was given its place in the ladder BEFORE the
    // foundation (decision 69 says it gets a place of its own but does not say
    // where). Before it means: what pays for adjudication is taken off the top,
    // and the foundation's share is a share of income rather than of what
    // adjudication left. Under the flat shares used here the two orderings
    // differ only in how the arithmetic reads, not in what anyone gets — but
    // the ORDER is the promise this contract freezes, so it should be the
    // owner's sentence and not an executor's.

    /// CEILING on the foundation's share of income WHILE THE OWNER STILL
    /// GOVERNS. After the handover the ceiling is FOUNDATION_BPS_MAX_DAO; the
    /// switch between the two is foundationBpsCeiling().
    ///
    /// 6 000 (60%), and the number was chosen for what it LEAVES rather than
    /// for what it grants. 7 000 was proposed — it is what the live treasury
    /// pays the foundation today — and refused, because 7 000 + 1 000 + 2 000
    /// is exactly 10 000 and left the reserve a guaranteed floor of zero. At
    /// 6 000 the reserve keeps a tenth of all income that nothing readable can
    /// take from it (RESERVE_BPS_MIN).
    ///
    /// ⚠️ So this is a CUT against what the live treasury pays today, and it is
    /// deliberate: the foundation's 70% was never a floor either — it is a
    /// ceiling here, and the readable number under it is the owner's to set at
    /// any value up to 6 000.
    ///
    /// Too low: the foundation can never again be paid what it is being paid
    /// today, and fixing that costs another contract replacement plus the
    /// accumulated reserve. Too high: an owner who is also the foundation can
    /// route up to this fraction of ALL protocol income to himself forever, and
    /// nothing in this contract can stop him — and every point of it comes out
    /// of the reserve's floor, one for one.
    uint256 public constant FOUNDATION_BPS_MAX = 6_000;

    /// The SAME ceiling, in force once the diamond says governance has been
    /// handed over. 2 000 (20%) — the post-DAO share the live treasury already
    /// pays, unchanged.
    ///
    /// ⚠️ IT IS NOT COUNTED IN RESERVE_BPS_MIN, and that is not an oversight:
    /// the floor must hold in the WORST case, and the worst case is the higher
    /// ceiling. Being stricter after the handover only ever gives the reserve
    /// more.
    ///
    /// ⚠️⚠️ THE PRICE OF LATCHING IT, NAMED AND ACCEPTED BY THE OWNER ON
    /// 4 SEPTEMBER 2026. Once daoLatched is set this ceiling is in force
    /// forever, so ONE spurious `true` out of the diamond — a broken upgrade is
    /// enough, no hostility required — cuts the foundation's ceiling to 2 000
    /// permanently, and nothing in this contract can raise it again. That is
    /// not an oversight and it is not a bug report waiting to be filed: it is
    /// the deliberate other half of activateDAO() being irreversible. The
    /// owner weighed it this way: either way a single mistake of his own sends
    /// everything into the DAO, there is no way back from that in any case —
    /// and a way back would not be logical to have.
    /// A treasury with a way back would be a way back around an irreversible
    /// handover, and that is worth more than the risk of a wrong `true`.
    ///
    /// Too low: a foundation that still has work to do after the handover is
    /// underfunded, and only a new contract can raise it. Too high: the
    /// handover stops meaning what the live treasury made it mean.
    uint256 public constant FOUNDATION_BPS_MAX_DAO = 2_000;

    /// CEILING on the arbiter vault's share of income.
    ///
    /// 1 000 (10%) — the number decision 47 named for exactly this share on
    /// 26 August 2026, after the owner looked at open market data. Taken as it
    /// stood on 4 September 2026.
    /// The vault is additionally bounded by its target, so this ceiling governs
    /// only how FAST it fills.
    ///
    /// Too low: the vault fills more slowly than disputes drain it and has to
    /// be topped up out of the reserve, or by hand — recoverable, because
    /// topUpVault() exists and because the diamond owner may always fundVault()
    /// out of his own pocket. Too high: income piles into a pot that sits under
    /// the diamond key, and it gets there before the reserve sees any of it.
    uint256 public constant VAULT_BPS_MAX = 1_000;

    /// CEILING on the arbiter payroll's share of income (decision 69).
    ///
    /// 2 000 (20%), taken as it stood on 4 September 2026. ⚠️ The SHARE itself
    /// (as opposed to this ceiling over it) was refused by the owner on
    /// 4 September 2026 — "not 80%, needs thinking about separately" — and that
    /// is why the share is read rather than frozen. This is the ceiling over it,
    /// which is a different question and still an open one: it is the largest
    /// slice of income that could ever be committed to paying for adjudication.
    ///
    /// Too low: the stream cannot be made big enough to pay arbiters properly
    /// once real disputes appear, and the fix is another contract. Too high: it
    /// crowds out the reserve, and it is money moved into the diamond early.
    uint256 public constant PAYROLL_BPS_MAX = 2_000;

    /// What the reserve is guaranteed no matter how the three readable shares
    /// are set. It is not a chosen number — it is what the three ceilings above
    /// leave over, and it is stated as a constant so the choice cannot be made
    /// without seeing its consequence.
    ///
    /// ⚠️ This line is also the compile-time proof that the ladder cannot
    /// underflow: if the three ceilings ever sum above 100%, this constant
    /// expression goes negative and solc refuses the file. The check cannot be
    /// forgotten because it is not a check.
    ///
    /// ⚠️ THE COMPILER ONLY CATCHES THE SUM GOING ABOVE 10 000. At exactly
    /// 10 000 this expression is 0, the file compiles, every existing test stays
    /// green and the reserve's floor is simply gone — which is where the three
    /// ceilings stood until 4 September 2026. What catches THAT is a test, and
    /// it is named here so the next reader can find it:
    /// test_TheThreeCeilingsLeaveTheReserveATenthAndThatIsItsFloor in
    /// test/ProtocolTreasury.t.sol reddens the moment the sum reaches 10 000.
    /// Raising any one of the three ceilings means answering it.
    ///
    /// Today: 10 000 − 6 000 − 1 000 − 2 000 = 1 000, a tenth of all income.
    /// FOUNDATION_BPS_MAX_DAO is deliberately NOT part of this subtraction —
    /// the floor has to hold in the worst case, and the worst case is the
    /// higher of the two foundation ceilings.
    uint256 public constant RESERVE_BPS_MIN =
        BPS - FOUNDATION_BPS_MAX - VAULT_BPS_MAX - PAYROLL_BPS_MAX;

    /// CEILING on the vault target, in USDC (6 decimals).
    ///
    /// 50 000 USDC, taken as it stood on 4 September 2026. The live treasury
    /// freezes the target itself at
    /// 500 USDC; this is a ceiling a hundred times above it, which is the point
    /// — the target must be free to follow real dispute volume, and only the
    /// worst case needs bounding.
    ///
    /// Too low: the vault can never be sized for a busy protocol. Mild, because
    /// the owner can always fund the vault directly out of his own pocket and
    /// because the reserve can top it up. Too high: the owner can park income in
    /// the vault instead of letting it reach the reserve — bounded per
    /// distribution by VAULT_BPS_MAX, but unbounded in total.
    uint256 public constant VAULT_TARGET_MAX = 50_000_000_000;

    /// The foundation's share when its number cannot be read.
    ///
    /// A FLOOR, not a default: it is what the foundation gets when the diamond
    /// stops answering, and it is deliberately the smaller of the two shares
    /// the old treasury used, so that breaking the read costs the only party
    /// able to break it. 2 000 (20%), taken as it stood on 4 September 2026:
    /// it is the old contract's post-DAO share and the value its foundationBps()
    /// already degraded to, and it is also FOUNDATION_BPS_MAX_DAO, so after the
    /// handover a dead read costs the foundation nothing extra.
    ///
    /// ⚠️ It is also what the foundation gets on day one if this treasury is
    /// installed before getTreasuryFoundationBps() is mounted. Setting it to
    /// zero would be safer against manipulation and would silently pay the
    /// foundation nothing for however long that window lasts.
    uint256 public constant FOUNDATION_BPS_UNREAD = 2_000;

    /// Gas cap on a single read from the diamond. Carried over unchanged from
    /// the live treasury, where the reasoning was written and the number
    /// argued: an honest read is a fallback, a delegatecall and an SLOAD or two
    /// — order of 10 000 gas cold — and a tenfold margin bounds the worst case
    /// hard. distribute() makes at most SIX of these — the vault share, the
    /// vault target, the vault balance, the payroll share, the foundation share
    /// and isDaoActive() — so the ceiling on what a hostile view facet can cost
    /// the distribution is 600 000 gas, whatever the facet does. (It was five
    /// until the foundation's ceiling started moving with the handover.)
    uint256 private constant DIAMOND_VIEW_GAS = 100_000;

    // ==========================================================
    //  IMMUTABLE
    // ==========================================================

    address public immutable usdc;
    address public immutable diamond;

    /// A single address. What stands behind it — team, investor,
    /// infrastructure — the treasury does not know and must not know: that is a
    /// paper agreement, not code. There is no function to change it, and that
    /// absence is the promise.
    address public immutable foundation;

    // ==========================================================
    //  STORAGE — the four pots
    // ==========================================================
    //
    // Every cent held by this contract is in exactly one of five places: the
    // four pots below, or the undistributed remainder, which is not stored but
    // derived (pendingDistribution). The invariant
    //
    //     USDC.balanceOf(this) == vaultOwed + payrollOwed + foundationOwed
    //                           + reserveBalance + pendingDistribution()
    //
    // holds after every function in this file, and USDC sent here by anyone,
    // for any reason, simply grows the last term.

    /// Income laddered to the arbiter vault, not yet pushed into the diamond.
    uint256 public vaultOwed;

    /// Income laddered to the arbiter payroll, not yet pushed into the diamond.
    uint256 public payrollOwed;

    /// Owed to the foundation and not yet claimed.
    ///
    /// Pull, not push, and for a reason that is not style: USDC has a Circle
    /// blacklist. If the foundation address landed on it, a transfer inside
    /// distribute() would revert and take the whole distribution with it,
    /// forever, because the address is immutable and there is nothing to route
    /// around it. Decision 56 states the rule the protocol follows everywhere:
    /// money the protocol owes is put on a shelf, never pushed.
    uint256 public foundationOwed;

    /// The reserve. Two exits: topUpVault(), open to anyone but only ever for
    /// the vault's shortfall, and withdrawReserve(), gated on the DAO.
    uint256 public reserveBalance;

    // ==========================================================
    //  STORAGE — the one thing this contract REMEMBERS
    // ==========================================================

    /// Has this contract ever seen the diamond say that governance was handed
    /// over. Once true it is never false again, and there is no function that
    /// could clear it.
    ///
    /// WHY IT IS REMEMBERED AT ALL, when every other number here is re-read.
    /// Because activateDAO() is the one thing on the diamond that is meant to
    /// be irreversible: the flag it sets is written in exactly one place in
    /// src/ and cleared in none. A treasury that only ever re-read it would
    /// hand that irreversibility back — one diamondCut replacing the facet with
    /// a copy answering `false`, and the foundation's ceiling climbs from
    /// FOUNDATION_BPS_MAX_DAO to FOUNDATION_BPS_MAX again. The owner's sentence
    /// on 4 September 2026: a way back would not be logical to have. So the
    /// treasury keeps
    /// its own copy, and after that the diamond's answer no longer matters.
    ///
    /// ⚠️ WHAT SETS IT, EXACTLY: an ANSWERED read that says true, and nothing
    /// else. A read that did not come back gives the strict ceiling — that is
    /// the degradation rule, unchanged — but is NEVER remembered. The two are
    /// different things: erring against the foundation while a facet is broken
    /// is cheap and reversible; remembering the breakage would turn a temporary
    /// fault into a permanent cut on a contract that cannot be patched.
    ///
    /// WHAT LATCHES IT: distribute(), as a side effect of asking the question
    /// it was going to ask anyway, and latchDao(), which anybody may call so
    /// that nailing the handover down does not have to wait for money to move.
    /// Between activateDAO() and the first of those two calls the flag is not
    /// yet remembered — a window nothing inside a contract can close, because a
    /// contract cannot watch another one. latchDao() exists to make that window
    /// one transaction wide for anyone who cares to close it.
    bool public daoLatched;

    // ==========================================================
    //  REENTRANCY
    // ==========================================================
    //
    // The same minimal guard as the live treasury and as Agreement.sol, with no
    // external dependency. Note that distribute() no longer makes any call that
    // could reenter — it touches the diamond only through staticcalls and the
    // token only through balanceOf — and it keeps the guard anyway: a future
    // reader must not have to re-derive that, and the cost is one warm SSTORE.

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status;

    modifier nonReentrant() {
        if (_status == ENTERED) revert Reentrancy();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    // ==========================================================
    //  EVENTS
    // ==========================================================

    /// Income that had arrived since the last call has been apportioned into
    /// the four claims. NOTHING HAS MOVED: this event is the moment four
    /// counters inside this contract grow, and the money leaves later through
    /// pushVault(), pushPayroll(), withdrawFoundation() and withdrawReserve(),
    /// each of which has its own event.
    ///
    /// ⚠️ WHY IT IS NOT CALLED `Distributed`, although the function is still
    /// distribute(). Because src/Treasury.sol — the treasury deployed at
    /// 0x2e7a7A05, still live, still indexed — declares
    /// `Distributed(uint256,uint256,uint256)`, three fields to these four. One
    /// name over two shapes is not a cosmetic clash: a reader holding a mini-ABI
    /// gets whichever declaration it happened to register, and the other one
    /// decodes to null in silence. That is the defect
    /// relayer/test/miniAbiEventsMatchFacets.test.js (R-E4) exists to name, and
    /// on 4 September 2026 it was red on exactly this pair.
    ///
    /// And the old name was never true here in any case. There `Distributed`
    /// reports a real transfer — its first field is `spent`, what the vault
    /// actually took through a call() made inside distribute(). Here the first
    /// field is what was BOOKED to the vault; the raw call is gone (see "THE ONE
    /// STRUCTURAL CHANGE AGAINST THE OLD TREASURY" in the header), so no
    /// distribution happens at this line at all. An allocation does.
    event IncomeAllocated(uint256 toVault, uint256 toPayroll, uint256 toFoundation, uint256 toReserve);
    event VaultPushed(uint256 amount);
    event PayrollPushed(uint256 amount);
    event VaultToppedUpFromReserve(uint256 amount);
    event ReserveWithdrawn(address indexed dao, uint256 amount);
    event FoundationWithdrawn(uint256 amount);

    /// The handover has been seen and written down. Emitted exactly once in the
    /// life of this contract, because daoLatched is written exactly once.
    event DaoLatched();

    // ==========================================================
    //  ERRORS
    // ==========================================================

    error ZeroAddress();
    error NoCode();
    error NothingToDistribute();
    error NothingOwed();
    error TransferFailed();
    error ApproveFailed();
    error Reentrancy();
    error VaultAtTarget();
    error ReserveEmpty();
    error DiamondFundingFailed();
    error DiamondPotDidNotGrow();
    error DaoNotEarned();
    error DaoAddressUnset();
    error NotDao();
    error InvalidAmount();
    error DaoAlreadyLatched();
    error DaoNotHandedOver();

    /// A read this contract is not allowed to guess at came back unusable — the
    /// selector is gone, the facet reverted, or it tried to spend more than
    /// DIAMOND_VIEW_GAS instead of answering. Carries the selector so the
    /// refusal names which read died.
    error DiamondReadFailed(bytes4 selector);

    constructor(address usdc_, address diamond_, address foundation_) {
        if (usdc_ == address(0) || diamond_ == address(0) || foundation_ == address(0)) revert ZeroAddress();
        // Both external addresses must carry code. In the EVM a call to an
        // address without code returns SUCCESS: for the diamond that would mean
        // a push "succeeded" while the money stayed here, and for USDC it would
        // mean balanceOf and transfer silently answer emptiness instead of
        // failing, which takes the footing out from under the whole accounting.
        if (usdc_.code.length == 0) revert NoCode();
        if (diamond_.code.length == 0) revert NoCode();
        usdc       = usdc_;
        diamond    = diamond_;
        foundation = foundation_;
        _status    = NOT_ENTERED;
    }

    // ==========================================================
    //  THE LADDER
    // ==========================================================

    /// @notice Ladder everything that has arrived since last time into the four
    /// pots. Anyone may call it: ERC-20 has no callback, so the treasury cannot
    /// learn of an incoming fee at the moment it arrives.
    ///
    /// WHAT THE RIGHT TO CALL CONFERS: nothing, and here that is checkable
    /// rather than merely claimed. The three shares are shares of the SAME
    /// base, so each recipient's take depends only on its own readable number
    /// and on how much has arrived — not on the vault's state, not on the order
    /// in which the open functions are called, not on who calls them. The
    /// caller still chooses the MOMENT, and the readable numbers can move
    /// between blocks; what he cannot do is move money between recipients.
    ///
    /// This is the difference from the live treasury, where the vault was the
    /// first step and took everything up to its shortfall: there the vault's
    /// state changed the foundation's take, which is what made calling
    /// topUpVault() before distribute() worth 210 USDC a round to the
    /// foundation, and what the DistributeFirst gate had to be built to stop.
    function distribute() external nonReentrant {
        uint256 pending = pendingDistribution();
        if (pending == 0) revert NothingToDistribute();

        // Step 1 — the vault, up to its shortfall and not a cent past it.
        //
        // vaultRoom() counts what is ALREADY owed to the vault but not yet
        // pushed, so a distribution that happens before pushVault() cannot
        // promise the same shortfall twice.
        uint256 toVault = 0;
        uint256 vBps = vaultBps();
        if (vBps != 0) {
            uint256 room = vaultRoom();
            if (room != 0) {
                toVault = (pending * vBps) / BPS;
                if (toVault > room) toVault = room;
            }
        }

        // Step 2 — the arbiter payroll (decision 69). It has no target and no
        // room: what it is for is paying for work that has already been done,
        // and how it is split among arbiters is the diamond's business, not
        // this contract's.
        uint256 toPayroll = (pending * payrollBps()) / BPS;

        // Step 3 — the foundation. This is the one step of the ladder that can
        // WRITE, and only ever once: asking which ceiling is in force is also
        // how a handover gets remembered (daoLatched). It writes nothing on any
        // other answer, so the ordinary distribution is unchanged.
        uint256 toFoundation = (pending * _foundationBpsLatching()) / BPS;

        // Step 4 — the reserve takes the whole remainder. By subtraction rather
        // than as a fourth share, so no cent can be lost to rounding, and every
        // cent rounded off the three shares above lands here.
        //
        // This cannot underflow: each share is at most its frozen ceiling, the
        // three ceilings sum to at most BPS (RESERVE_BPS_MIN is the compiler's
        // proof of that), and a sum of floors is never above the floor of a sum.
        uint256 toReserve = pending - toVault - toPayroll - toFoundation;

        if (toVault != 0)      vaultOwed      += toVault;
        if (toPayroll != 0)    payrollOwed    += toPayroll;
        if (toFoundation != 0) foundationOwed += toFoundation;
        if (toReserve != 0)    reserveBalance += toReserve;

        emit IncomeAllocated(toVault, toPayroll, toFoundation, toReserve);
    }

    // ==========================================================
    //  REMEMBERING THE HANDOVER
    // ==========================================================

    /// @notice Write down, permanently, that governance has been handed over.
    ///
    /// distribute() already does this by itself, so this function exists for
    /// one reason: the window. activateDAO() happens in the diamond and this
    /// contract cannot watch it — it only learns of the handover the next time
    /// somebody calls distribute(). Until then a diamondCut could still put the
    /// flag back and lift the foundation's ceiling. latchDao() makes that
    /// window one transaction wide for anyone who cares to close it.
    ///
    /// ANYONE MAY CALL IT, and the right to call confers nothing — literally
    /// nothing, because the caller supplies no argument and the outcome depends
    /// only on what the diamond answers. It can move the ceiling in one
    /// direction, down, and only when the diamond itself says the handover has
    /// happened. It cannot be used to cut the foundation early, and it cannot
    /// be used to spend a cent.
    ///
    /// Both refusals name what actually happened rather than sharing one word
    /// for "no": a diamond that did not answer is a different situation from a
    /// diamond that answered "not yet", and only the first is somebody's fault.
    function latchDao() external nonReentrant {
        if (daoLatched) revert DaoAlreadyLatched();

        (, bool latchable, bool answered) = _handoverCeiling();
        if (!answered) revert DiamondReadFailed(IHexsealDiamond.isDaoActive.selector);
        if (!latchable) revert DaoNotHandedOver();

        _latch();
    }

    // ==========================================================
    //  PUSHING MONEY INTO THE DIAMOND
    // ==========================================================

    /// @notice Send everything owed to the arbiter vault into the diamond.
    /// Permissionless, and it decides nothing: the amount is whatever the
    /// ladder already assigned, and the destination is fixed.
    ///
    /// ALL OR NOTHING, deliberately. If the diamond does not take the money, or
    /// takes it without its own vault growing, this reverts and the debt stays
    /// exactly where it was, to be pushed again another day. The live treasury
    /// could not afford this strictness — a revert there would have walled up
    /// the entire distribution — and the price of that was measured: a broken
    /// fundVault swallowed 2 000 USDC across ten calls while every call emitted
    /// a successful-looking event. Separating the push from the ladder is what
    /// buys the strictness back.
    function pushVault() external nonReentrant {
        uint256 amount = vaultOwed;
        if (amount == 0) revert NothingOwed();
        vaultOwed = 0;

        // Not clamped to the CURRENT room on purpose. This money was laddered
        // under the target that was readable at that moment; re-judging it
        // against a target that has since been lowered would leave a pot with
        // no door — the money could never be pushed and there is no other exit
        // from vaultOwed. Decision 52 is the same rule for deals: what has
        // started lives by the rules in force when it started.
        _pushToDiamond(
            IHexsealDiamond.fundVault.selector,
            IHexsealDiamond.getVaultBalance.selector,
            amount
        );
        emit VaultPushed(amount);
    }

    /// @notice Send everything owed to the arbiter payroll into the diamond.
    /// Same shape and the same strictness as pushVault().
    ///
    /// ⚠️ fundArbiterPayroll() and getArbiterPayrollBalance() are not mounted on
    /// the diamond yet (see the file header). Until they are, this function
    /// reverts and the payroll debt simply accumulates — which is also why the
    /// payroll SHARE degrades to zero when unreadable: a pot no one can pay into
    /// should not be filling.
    function pushPayroll() external nonReentrant {
        uint256 amount = payrollOwed;
        if (amount == 0) revert NothingOwed();
        payrollOwed = 0;

        _pushToDiamond(
            IHexsealDiamond.fundArbiterPayroll.selector,
            IHexsealDiamond.getArbiterPayrollBalance.selector,
            amount
        );
        emit PayrollPushed(amount);
    }

    /// @notice Top the arbiter vault up out of the RESERVE, when income has not
    /// been enough. The reserve's only exit before the DAO exists.
    ///
    /// Anyone may call it, and the right to call confers nothing: it moves the
    /// vault's shortfall and no more, refuses on a full vault, and — because
    /// the shares in distribute() are flat — cannot shift a cent between
    /// recipients whichever order it is called in. That last property is why
    /// this contract has no DistributeFirst gate: the gate existed only to stop
    /// the reordering from paying the foundation, and under flat shares the
    /// reordering pays nobody. Its absence also removes the hole it carried,
    /// where 1 wei of USDC sent here by a stranger walled this function up.
    ///
    /// What the caller does still influence is the AMOUNT, by choosing a moment
    /// (a call right after a large arbiter payout moves more than one before
    /// it), and the state it computes from is moved by the diamond owner. That
    /// trust is unchanged from the live treasury and is not re-argued here.
    function topUpVault() external nonReentrant {
        uint256 room = vaultRoom();
        if (room == 0) revert VaultAtTarget();

        uint256 amount = room > reserveBalance ? reserveBalance : room;
        if (amount == 0) revert ReserveEmpty();

        // The reserve shrinks before the external call. Without the guard a
        // reentrant would see the reduced reserve while the vault is not yet
        // topped up, and debit the reserve twice for one shortfall.
        reserveBalance -= amount;
        _pushToDiamond(
            IHexsealDiamond.fundVault.selector,
            IHexsealDiamond.getVaultBalance.selector,
            amount
        );
        emit VaultToppedUpFromReserve(amount);
    }

    // ==========================================================
    //  MONEY LEAVING FOR PEOPLE
    // ==========================================================

    /// @notice Claim what has been credited to the foundation. Anyone may call
    /// it: the money leaves only for the immutable foundation address anyway,
    /// so the right to call decides nothing, while openness lets an outsider
    /// push the payout through if the foundation cannot be bothered.
    function withdrawFoundation() external nonReentrant {
        uint256 amount = foundationOwed;
        if (amount == 0) revert NothingOwed();
        foundationOwed = 0;
        if (!IUSDC(usdc).transfer(foundation, amount)) revert TransferFailed();
        emit FoundationWithdrawn(amount);
    }

    /// @notice Withdraw the reserve to the address the diamond names as the DAO.
    /// The DAO only, and only once the threshold the diamond names has been
    /// earned.
    ///
    /// BOTH SIDES OF THE GATE ARE NOW READ, and that is decision 65 rather than
    /// a slip: the live treasury froze the threshold at 100 000 while the
    /// diamond's own facet had already moved to 10 000, so the frozen number
    /// was not strictness, it was drift. It was not protection either — the same
    /// owner reaches the same result by three live paths, the cheapest of them
    /// measured at 31 717 gas and invisible in every loupe view. What the gate
    /// still does is exactly what it did before: it holds against the MANUAL DAO
    /// flag, and it makes the honest path a stated, readable number instead of
    /// a guess frozen into bytecode.
    ///
    /// A read that fails REVERTS here rather than degrading. Degradation is for
    /// the places where a dead read would wall up the ladder forever; this call
    /// is all-or-nothing, its revert locks nothing, and carrying on with an
    /// unread gate would hand out the reserve unchecked.
    function withdrawReserve(uint256 amount) external nonReentrant {
        // The threshold is asked for before the address on purpose: even with
        // no DAO address set, the answer must be "the DAO is not earned" rather
        // than "there is no address", or it would look from outside as though
        // setting an address alone opened the withdrawal.
        uint256 threshold = _requireDiamondWord(IHexsealDiamond.getDaoThreshold.selector);
        uint256 users     = _requireDiamondWord(IHexsealDiamond.getUniqueActiveUsers.selector);
        if (users < threshold) revert DaoNotEarned();

        address dao = _requireDiamondAddress(IHexsealDiamond.getDAOAddress.selector);
        if (dao == address(0)) revert DaoAddressUnset();
        if (msg.sender != dao) revert NotDao();
        if (amount == 0) revert InvalidAmount();

        // Take the lesser of requested and available rather than reverting on a
        // shortfall. Not convenience: topUpVault() is open to anyone and also
        // spends the reserve, so on a revert any outsider could break the DAO's
        // withdrawal by lawfully shrinking the reserve first. Clamping also
        // keeps undistributed money out of reach — the bound is reserveBalance,
        // not the contract's actual balance.
        uint256 toSend = amount > reserveBalance ? reserveBalance : amount;
        if (toSend == 0) revert ReserveEmpty();

        reserveBalance -= toSend;
        if (!IUSDC(usdc).transfer(dao, toSend)) revert TransferFailed();

        emit ReserveWithdrawn(dao, toSend);
    }

    // ==========================================================
    //  VIEWS — every readable number, clamped
    // ==========================================================

    /// What sits here above everything already assigned to a pot.
    function pendingDistribution() public view returns (uint256) {
        uint256 balance = IUSDC(usdc).balanceOf(address(this));
        uint256 earmarked = vaultOwed + payrollOwed + foundationOwed + reserveBalance;
        return balance > earmarked ? balance - earmarked : 0;
    }

    /// The vault's share of income, as read and then clamped.
    /// A failed read is ZERO: the money falls through to the reserve, which is
    /// the pot that can still be spent on the vault later through topUpVault().
    function vaultBps() public view returns (uint256) {
        (bool ok, uint256 bps) = _readDiamondWord(IHexsealDiamond.getTreasuryVaultBps.selector);
        if (!ok) return 0;
        return bps > VAULT_BPS_MAX ? VAULT_BPS_MAX : bps;
    }

    /// The arbiter payroll's share of income, as read and then clamped.
    /// A failed read is ZERO, for the same reason and one more: a facet that
    /// cannot answer what the payroll share is almost certainly cannot accept a
    /// payroll payment either, and filling a pot with no door is the mistake
    /// decision 47 named.
    function payrollBps() public view returns (uint256) {
        (bool ok, uint256 bps) = _readDiamondWord(IHexsealDiamond.getTreasuryPayrollBps.selector);
        if (!ok) return 0;
        return bps > PAYROLL_BPS_MAX ? PAYROLL_BPS_MAX : bps;
    }

    /// WHICH of the two foundation ceilings is in force right now.
    ///
    /// ⚠️ THIS IS THE HANDOVER, AND IT MOVES THE CEILING RATHER THAN THE VALUE.
    /// The live treasury switched the foundation's SHARE outright — 70% before
    /// the DAO, 20% after, both frozen — and that is the one thing that must
    /// NOT come back here. By the time governance is handed over the owner is
    /// expected to have tuned the readable share to a number of his own, and an
    /// automatic assignment would overwrite it: the protocol would come out of
    /// the handover running on a number nobody chose. Moving the CEILING makes
    /// the handover subtractive instead:
    ///
    ///     tuned to 50%  →  handover  →  20%   (only the excess is taken)
    ///     tuned to 15%  →  handover  →  15%   (a stricter setting survives)
    ///
    /// The automatic step still happens by itself and costs nobody a
    /// transaction; what it can no longer do is RAISE anything, or replace a
    /// setting that was already at least as strict as the new ceiling.
    ///
    /// AN UNREADABLE FLAG PICKS THE STRICTER CEILING — the same rule as
    /// everywhere else in this file: a read that does not come back is answered
    /// in the direction that costs whoever is able to break it. Here that means
    /// assuming the handover HAS happened, so removing isDaoActive() from the
    /// diamond cuts the foundation rather than freeing it.
    ///
    /// ⚠️ ONE WAY ONLY, AND THIS FILE IS WHAT GUARANTEES IT (4 September 2026).
    /// activateDAO() sets a flag that nothing anywhere in src/ ever clears — but
    /// the diamond is upgradeable, so re-reading it every time would have meant
    /// one diamondCut could put the ceiling back up and hand the reversal to the
    /// exact party the drop costs. The treasury therefore remembers: once it has
    /// seen an answered `true`, daoLatched short-circuits this function and the
    /// diamond's answer stops mattering. What that costs is written out at
    /// FOUNDATION_BPS_MAX_DAO and was accepted with its price named.
    ///
    /// ⚠️ THE ONE WINDOW LEFT: between activateDAO() and the first distribute()
    /// or latchDao(), nothing is remembered yet. No contract can close that on
    /// its own — a contract cannot watch another one — which is why latchDao()
    /// is permissionless.
    function foundationBpsCeiling() public view returns (uint256) {
        (uint256 ceiling,,) = _handoverCeiling();
        return ceiling;
    }

    /// The foundation's share of income, as read and then clamped by whichever
    /// ceiling is in force — see foundationBpsCeiling().
    /// A failed read is FOUNDATION_BPS_UNREAD — the floor, not the ceiling.
    /// The clamp is applied to the fallback as well, so the fallback can never
    /// be the loophole that beats the ceiling.
    ///
    /// This is the READ-ONLY twin of what the ladder uses. It cannot latch,
    /// because it is a view; distribute() goes through _foundationBpsLatching()
    /// for the same number and remembers the answer on its way past.
    function foundationBps() public view returns (uint256) {
        return _clampFoundationBps(foundationBpsCeiling());
    }

    /// The vault's target, as read and then clamped. A failed read is ZERO,
    /// which reads as "nothing to top up" and skips the vault step entirely.
    function vaultTarget() public view returns (uint256) {
        (bool ok, uint256 target) = _readDiamondWord(IHexsealDiamond.getVaultTarget.selector);
        if (!ok) return 0;
        return target > VAULT_TARGET_MAX ? VAULT_TARGET_MAX : target;
    }

    /// How much the arbiter vault is still short of its target, counting money
    /// this contract has already promised it but not yet pushed.
    ///
    /// A failed read of the vault balance is not a revert but 0, "nothing to top
    /// up": a removed or broken getVaultBalance() must not be able to freeze
    /// anything. That selector's facet has been upgraded about seven times in
    /// three months and fourteen scripts under script/ perform a Remove, so this
    /// is not a hypothetical.
    function vaultRoom() public view returns (uint256) {
        uint256 target = vaultTarget();
        if (target == 0) return 0;

        (bool ok, uint256 balance) = _readDiamondWord(IHexsealDiamond.getVaultBalance.selector);
        if (!ok) return 0;

        // ⚠️ SATURATING, and this line is a FIX, not a flourish. `balance` is a
        // word out of an upgradeable contract, and until 4 September 2026 this
        // addition was a plain `+`: a facet answering type(uint256).max made it
        // overflow, so vaultRoom() reverted with Panic(0x11) and took
        // distribute() down with it for as long as vaultOwed was non-zero.
        // MEASURED against the stand, not supposed. That broke the promise this
        // file makes about itself — every read here degrades, and a view facet
        // is not supposed to be able to kill the ladder — so it was the one
        // read that could.
        //
        // An overflowing sum can only mean a balance astronomically above any
        // target (the target is clamped to VAULT_TARGET_MAX), which is the same
        // conclusion as an honest huge balance: no room, skip the vault step.
        uint256 owed = vaultOwed;
        if (balance > type(uint256).max - owed) return 0;

        uint256 held = balance + owed;
        return held >= target ? 0 : target - held;
    }

    // ==========================================================
    //  INTERNAL
    // ==========================================================

    /// The handover question, answered in ONE place. Three facts come back
    /// because they are three DIFFERENT facts, and quietly merging them is
    /// exactly how the strict-ceiling rule would turn into a permanent cut:
    ///
    ///   ceiling    which of the two foundation ceilings is in force now;
    ///   latchable  whether this answer may be REMEMBERED. Only an answered
    ///              read that says `true` may be. A read that did not come back
    ///              also gives the strict ceiling — that is the degradation
    ///              rule and it is unchanged — but it is never latched, because
    ///              writing down a temporary fault would cut the foundation
    ///              forever on a contract nobody can patch;
    ///   answered   whether the diamond spoke at all. Only latchDao() needs it,
    ///              and only so its refusal can name what happened.
    ///
    /// Non-zero rather than exactly 1 counts as `true`, deliberately: a
    /// malformed non-zero word then errs towards the STRICT ceiling. Demanding
    /// exactly 1 would make a malformed answer pay the foundation, which is the
    /// wrong direction and the one this file never takes.
    function _handoverCeiling() private view returns (uint256 ceiling, bool latchable, bool answered) {
        if (daoLatched) return (FOUNDATION_BPS_MAX_DAO, false, true);

        (bool ok, uint256 daoActive) = _readDiamondWord(IHexsealDiamond.isDaoActive.selector);
        if (!ok) return (FOUNDATION_BPS_MAX_DAO, false, false);
        if (daoActive == 0) return (FOUNDATION_BPS_MAX, false, true);
        return (FOUNDATION_BPS_MAX_DAO, true, true);
    }

    /// The foundation's readable share, squeezed by a ceiling handed in. One
    /// implementation of the clamp for both the view and the ladder — a second
    /// copy would be a second place for the rule to drift, which is the same
    /// argument that keeps _readDiamondWord single.
    function _clampFoundationBps(uint256 ceiling) private view returns (uint256) {
        (bool ok, uint256 bps) = _readDiamondWord(IHexsealDiamond.getTreasuryFoundationBps.selector);
        if (!ok) bps = FOUNDATION_BPS_UNREAD;
        return bps > ceiling ? ceiling : bps;
    }

    /// What the ladder uses: the same number foundationBps() reports, and the
    /// one path that WRITES the handover down on its way past. It asks the
    /// question distribute() had to ask anyway, so remembering costs no extra
    /// read — only the single SSTORE, and only once in the contract's life.
    function _foundationBpsLatching() private returns (uint256) {
        (uint256 ceiling, bool latchable,) = _handoverCeiling();
        if (latchable) _latch();
        return _clampFoundationBps(ceiling);
    }

    /// The ONE place daoLatched is written. There is no companion that clears
    /// it, and that absence is the promise — see FOUNDATION_BPS_MAX_DAO for
    /// what it costs and why it was accepted.
    function _latch() private {
        daoLatched = true;
        emit DaoLatched();
    }

    /// Reads ONE 32-byte word from the diamond, leaving the callee no way to
    /// revert this transaction, burn its gas, or flood its memory.
    ///
    /// Three limits at once:
    ///   • staticcall — the callee can neither change state nor reenter
    ///     anything that writes;
    ///   • an output buffer of exactly 0x20 — the EVM will not copy more than
    ///     32 bytes into this memory, whatever the callee answers;
    ///   • gas bounded by DIAMOND_VIEW_GAS.
    ///
    /// An answer shorter than a word counts as a failure: success with empty
    /// returndata — a call to an address whose code has vanished, say — would
    /// otherwise pass uninitialised memory off as the value read.
    function _readDiamondWord(bytes4 selector) private view returns (bool ok, uint256 word) {
        address to = diamond;
        uint256 gasCap = DIAMOND_VIEW_GAS;
        assembly ("memory-safe") {
            // Scratch space past the free memory pointer: the pointer is not
            // moved and nothing long-lived stays here. In Yul a selector sits
            // left-aligned in a word, so mstore plus a length of 4 give exactly
            // four bytes of calldata. The output buffer is the same address —
            // the input is read before the EVM starts writing the answer.
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(gasCap, to, ptr, 4, ptr, 0x20)
            if lt(returndatasize(), 0x20) { ok := 0 }
            word := mload(ptr)
        }
        if (!ok) word = 0;
    }

    /// The same bounded read, for the call sites that must REVERT rather than
    /// degrade. There is one implementation of the read and two verdicts on its
    /// failure: a second copy of that assembly would be a second place for the
    /// rule to drift.
    function _requireDiamondWord(bytes4 selector) private view returns (uint256) {
        (bool ok, uint256 word) = _readDiamondWord(selector);
        if (!ok) revert DiamondReadFailed(selector);
        return word;
    }

    /// getDAOAddress() returns an address, not a word, so it needs the one
    /// thing _readDiamondWord cannot do on its own: reject a word that is not a
    /// valid address. Casting with uint160 would SILENTLY truncate a malformed
    /// answer into a plausible-looking wrong address; the failure direction
    /// would still be safe here, but "safe by accident" is not "checked", and
    /// the next reader would have no way to tell which one this was.
    function _requireDiamondAddress(bytes4 selector) private view returns (address) {
        uint256 word = _requireDiamondWord(selector);
        if (word > type(uint160).max) revert DiamondReadFailed(selector);
        return address(uint160(word));
    }

    /// Move `amount` of USDC into one of the diamond's pots, and refuse to
    /// believe it happened on anything less than proof.
    ///
    /// Two facts are checked, and they are different facts. `spent == amount`
    /// proves the USDC LEFT this contract — it is measured from our own balance
    /// rather than taken from the diamond's word for it. The postcondition on
    /// `potView` proves the diamond ACCOUNTED for it: a broken facet (a failed
    /// upgrade is enough, no hostility required) can honestly accept the
    /// transferFrom and forget to record the increase in its own counter, and
    /// that exact failure ate 2 000 USDC in a measurement on the live
    /// treasury's design. "At least", not "exactly": a future facet is entitled
    /// to credit MORE than it pulled, and forbidding that would be a rule with
    /// no reason behind it.
    ///
    /// The pot is read through the SAME capped path as everything else, but
    /// with the reverting verdict. The argument that the cap is unnecessary here
    /// because "control would not reach this line if the read were dead" is
    /// wrong and was measured to be wrong: the capped read hands a facet under
    /// DIAMOND_VIEW_GAS, an uncapped one hands it 63/64 of the transaction, and
    /// one gasleft() tells those apart — so the same selector can answer one
    /// caller honestly and eat the other.
    ///
    /// The write itself is a raw CALL with a zero-length output buffer. At the
    /// Solidity level `.call(...)` always copies ALL of returndata into memory
    /// before the code gets a chance to discard it, so a facet reverting with a
    /// megabyte payload would otherwise freeze this on gas. Here the returned
    /// data is not wanted at all, only the success flag, and with a zero-length
    /// buffer the EVM copies nothing.
    ///
    /// It is handed gas() rather than a frozen cap. See the file header for why
    /// — in short, the caller's own transaction gas limit is already that cap,
    /// it is adjustable and a constant would not be, and this call is not on
    /// the ladder any more.
    function _pushToDiamond(bytes4 fundSelector, bytes4 potView, uint256 amount) private {
        uint256 potBefore = _requireDiamondWord(potView);

        uint256 balanceBefore = IUSDC(usdc).balanceOf(address(this));
        if (!IUSDC(usdc).approve(diamond, amount)) revert ApproveFailed();

        address to = diamond;
        bytes memory payload = abi.encodeWithSelector(fundSelector, amount);
        bool ok;
        assembly ("memory-safe") {
            ok := call(gas(), to, 0, add(payload, 0x20), mload(payload), 0, 0)
        }

        // The approval is zeroed whatever the outcome above. ⚠️ Honestly: under
        // the strict push below this line is defence in depth and nothing more,
        // and that was measured rather than assumed -- deleting it leaves the
        // whole suite green, because every route that could leave an allowance
        // standing ends in a revert that undoes the approve anyway. It stays
        // because a future token that does not decrement on transferFrom would
        // make it load-bearing again, and it costs a refunded SSTORE.
        if (!IUSDC(usdc).approve(diamond, 0)) revert ApproveFailed();

        uint256 balanceAfter = IUSDC(usdc).balanceOf(address(this));
        // If the balance did not fall (including an unexpected rise), nothing
        // was spent. Subtracting the other way round would be a Panic 0x11.
        uint256 spent = balanceAfter < balanceBefore ? balanceBefore - balanceAfter : 0;

        if (!ok || spent != amount) revert DiamondFundingFailed();

        uint256 potAfter = _requireDiamondWord(potView);
        if (potAfter < potBefore + amount) revert DiamondPotDidNotGrow();
    }
}
