// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — TreasuryLinkFacet.sol
//
// The diamond's end of the conversation with the treasury.
//
// `src/ProtocolTreasury.sol` (decision 65) freezes its SHAPE forever and reads
// its NUMBERS off the diamond, so that a wrong number costs a diamondCut
// instead of a replaced contract and a lost reserve. Twelve selectors make up
// that conversation; six of them existed on the live diamond
// (0x760F07367888C62f7c2Dfb619A5e534132855ce5) on 4 September 2026 and six did
// not — measured with the loupe, not read out of a document:
//
//     mounted, facet 0x508a708c…   fundVault, getVaultBalance,
//                                  getDaoThreshold, getDAOAddress, isDaoActive
//     mounted, facet 0x21c9dEFf…   getUniqueActiveUsers
//     NOT MOUNTED, address(0)      fundArbiterPayroll, getArbiterPayrollBalance,
//                                  getVaultTarget, getTreasuryVaultBps,
//                                  getTreasuryPayrollBps,
//                                  getTreasuryFoundationBps
//
// This file is the six that were missing, plus the setters and the readback
// they need in order to be numbers a person can move rather than constants.
//
// ------------------------------------------------------------
// WHY A SEPARATE FACET, AND WHY NOT THE NEIGHBOUR
//
//   * `ArbiterRegistryFacet` — 24 367 bytes of the 24 576 EIP-170 allows,
//     measured with `forge build --sizes`. 209 bytes of margin is not room for
//     five storage fields, two setters and seven views. It is also the facet
//     whose fifty-odd selectors would all have to be REPLACED in the same cut,
//     and a `Replace`/`Add` pair is the operation that drops a whole cut on one
//     transaction.
//   * `ArbiterAccountabilityFacet` (15 617 free) and `ArbiterApplicationsFacet`
//     (20 046 free) both have the room and both are the wrong home. One is
//     named after conduct, the other after admissions; the treasury's dials are
//     neither, and filing them under either name makes the name a half-truth
//     that the next reader pays for. That argument is not new here — it is the
//     one written down when applications were cut out rather than folded in.
//
// Being a facet of its own also means every selector below is an `Add` and not
// one is a `Replace`. The upcoming cut therefore has no mixed group at all,
// which is the single arrangement in which a mistake takes down the whole
// diamondCut rather than one function.
//
// ------------------------------------------------------------
// STORAGE LIVES IN `ArbiterRegistryStorage`, NOT IN A NAMESPACE OF ITS OWN
//
// Same POSITION, same struct, five fields APPENDED at the end — exactly the
// arrangement `ArbiterAccountabilityFacet` and `ArbiterApplicationsFacet`
// already use, and the same one the boards use against `FactoryStorage`.
// Three reasons, in order of weight:
//
//   1. Every number the treasury ALREADY reads off the live diamond is in this
//      namespace: `vaultBalance`, `daoAddress`, `daoActiveManual`. Putting the
//      other half somewhere else would split one conversation across two
//      namespaces, and the first person to add a thirteenth selector would have
//      to guess which half it belongs to.
//   2. `arbiterPayrollBalance` is the sibling of `vaultBalance` — the second
//      pot of arbiter money the diamond holds. Its future spender (decision 69:
//      the stream is shared out among arbiters who actually worked in the
//      period, gated by a judicial-work counter) will read the work counters,
//      and those are in this namespace too.
//   3. No new namespace means no new ERC-7201 constant to derive and get wrong,
//      and the nine base slots pinned by test/StorageLayout.t.sol do not move.
//
// Append-only, and the gate that enforces it is script/check-storage-structs.sh
// — the one written after a field's TYPE was changed inside its own slot in
// July 2026 and `getOpenJobs()` began reverting Panic(0x22) on a live chain.
//
// ------------------------------------------------------------
// WHO MAY PAY IN — THE PRECEDENT, REUSED WITHOUT A NEW FIELD
//
// `fundArbiterPayroll` is gated exactly as `ArbiterRegistryFacet.fundVault`:
// the diamond owner, or whoever `FactoryStorage.feeRecipient` names right now.
// The fee recipient IS the treasury, because that is what installing a treasury
// means. The right to pay in therefore rides on the right to receive income,
// with no second address to set and nothing to forget when the treasury is
// replaced.
//
// ⚠️ WHAT THAT COSTS, SAID OUT LOUD. On 4 September 2026 `getFeeRecipient()`
// still answers 0x2e7a7A0515bfDC0006A812EBb3E55d32800Bc660 — the OLD treasury
// (measured on chain). So between the cut and `setFeeRecipient`, the address
// allowed to pay the payroll in is the old contract, which has never heard of
// this selector. That is harmless and it does not reorder anything: the new
// treasury only needs the right at PUSH time, and by then it is the fee
// recipient. If a push is attempted before the seat changes hands it reverts
// and the debt stays owed — `pushPayroll()` is retryable by design and nothing
// is lost. The rollout order in the treasury's own header (mount first, install
// second) is the right one and this gate does not change it.
//
// ⚠️ THE ORDER HAS A THIRD STEP THE HEADER DOES NOT NAME. All five fields below
// read ZERO on a diamond that has just been cut, and zero is a legitimate,
// silent answer: the vault share is nothing, the payroll share is nothing, the
// target is nothing. The treasury then ladders every distribution straight into
// the reserve, and money laddered that way is never re-laddered. So the numbers
// must be set in the SAME transaction as the cut, through the cut's own init
// call — which is why the three shares are ONE setter and not three, and why
// there is a separate readback for the dispute count.
//
// ⚠️ AN EARLIER VERSION OF THIS PARAGRAPH TOLD YOU TO KEEP THE PAYROLL SHARE
// AT ZERO until the payout existed. THE OWNER DECIDED OTHERWISE on 4 September
// 2026 (decision 74): the share ships at its target 2 000 from the first cut.
//
// The argument that was withdrawn: money entering a pot nothing can spend is
// money locked. It is answered by where the pot LIVES — `arbiterPayrollBalance`
// sits in the diamond's storage, so the payout (decision 73) arrives by an
// ordinary cut and can never force the immutable treasury to be replaced.
// Nothing is locked; it accumulates in the open, and we get to watch it do so
// on real numbers before the payout is built.
//
// This is left as a struck-through instruction rather than deleted, because an
// instruction that was right last week is exactly what makes the next person
// "fix" the cut back to zero and call it a repair.
// ============================================================

import {ArbiterRegistryStorage, ArbiterRegistryFacet, IUSDCFull} from "./ArbiterRegistryFacet.sol";
// `getArbiterFloor()` moved out of the registry into ArbiterVaultFacet on
// 16 September 2026 (the EIP-170 split). The SELECTOR did not change and the
// self-call below still routes through the diamond exactly as before — only the
// type whose `.getArbiterFloor` is named here had to follow the function.
import {ArbiterVaultFacet} from "./ArbiterVaultFacet.sol";
import {OwnershipLib} from "../DiamondProxy.sol";
import {FactoryStorage} from "../FactoryFacet.sol";

contract TreasuryLinkFacet {

    // ==========================================================
    //  CONSTANTS
    // ==========================================================

    /// The whole, in basis points. Not a promise about any share — the frozen
    /// ceilings are in the treasury and cannot be moved from here — only the
    /// arithmetic bound that makes the three numbers below readable as shares.
    uint256 private constant BPS = 10_000;

    // ==========================================================
    //  ERRORS
    // ==========================================================

    error NotOwner();
    /// Same name and same meaning as `ArbiterRegistryFacet.NotOwnerOrFeeRecipient`.
    /// A separate declaration because facets of a diamond do not inherit from
    /// one another; the selector is the same four bytes, so a caller decoding
    /// the refusal by name does not need to know which facet answered.
    error NotOwnerOrFeeRecipient();
    error ShareAboveWhole();
    error SharesExceedWhole();
    error TransferFailed();

    // ── The arbiter bank's surplus door (24 September 2026, mainnet item D2) ──

    /// The bank has no surplus: what it holds above the appeal debts it owes is
    /// at or below its target. Its own error rather than a shared "nothing to
    /// push": `ArbiterVaultFacet.withdrawTreasurySlice` already answers
    /// `NothingToPush` for a different pot with a different addressee, and a
    /// person told the wrong one of those learns nothing.
    error NoVaultSurplus();

    /// ⚠️ THE TARGET READS ZERO, AND ZERO IS A REFUSAL — NOT A PERMISSION.
    /// `getVaultTarget()` answers 0 for "no target set", which the treasury
    /// deliberately reads as "nothing to top up". A surplus door that subtracted
    /// that zero would find the WHOLE BANK to be surplus and send all of it away
    /// on one press by anybody — penalties, subsidies and buffer together. This
    /// error is what that arithmetic is replaced by.
    error VaultTargetUnset();

    /// The door could not learn where the money goes: `FactoryStorage.feeRecipient`
    /// is unset, is not a treasury (its `foundation()` answers nothing), or names
    /// the zero address. Refusing is the only safe branch, because the presser
    /// does not name the recipient and there is no fallback that is not a
    /// different decision.
    error FoundationUnreachable();

    // ── The payroll pot's door out (25 September 2026, mainnet item D3) ──

    /// The period named is the current one, or still in the future. A share can
    /// only be divided once the pot and the case count have both stopped
    /// moving, and both move until the period ends.
    error PayrollPeriodOpen();

    /// Nobody closed a case in that period, so there is no denominator and
    /// nothing to divide by.
    ///
    /// ⚠️ ITS OWN ERROR, SEPARATE FROM `NoPayrollShare`, and the distinction is
    /// the whole point: "nobody earned anything here" and "you earned nothing
    /// here" are different facts with different next steps, and a person told
    /// the wrong one of them learns something false about his own record. It is
    /// also the branch that would otherwise be a division by zero — a
    /// `Panic(0x12)` that says nothing to anybody.
    error PayrollPeriodHasNoCases();

    /// This arbiter has nothing coming out of that period: no case that stood,
    /// or a share already booked, or a pot too small to divide into a whole base
    /// unit for his fraction of it.
    error NoPayrollShare();

    /// The claim window has not run out yet. Whoever earned a share in that
    /// period may still come for it, and the remainder is not a remainder until
    /// they cannot.
    error PayrollPeriodNotLapsed();

    /// That period's pot is empty: every share has been booked, or the
    /// remainder has already been pushed out.
    error NoPayrollRemainder();

    // ==========================================================
    //  EVENTS
    // ==========================================================

    event ArbiterPayrollFunded(address indexed from, uint256 amount);
    event TreasurySharesUpdated(uint256 vaultBps, uint256 payrollBps, uint256 foundationBps);
    event VaultTargetDisputesUpdated(uint256 disputes);
    /// The bank's surplus, pushed out to the foundation. `target` travels with
    /// the amount because the amount alone says nothing about WHY it was that
    /// amount: the target moves when either the dispute count or the arbiter
    /// floor moves, and a log carrying only the sum would leave a reader unable
    /// to tell a bigger bank from a lower target.
    event VaultSurplusPushed(address indexed to, uint256 amount, uint256 target);

    /// A period's share, booked to the arbiter who earned it.
    ///
    /// The two case counts travel with the amount because the amount alone is
    /// unauditable: the same sum can be a large share of a small pot or a small
    /// share of a large one, and a reader who wants to check the division needs
    /// both sides of the fraction. Carried in the log rather than looked up,
    /// because the pot goes on being spent after this line and a later reader
    /// would divide by what is left instead of by what there was.
    event PayrollShareBooked(
        uint256 indexed period,
        address indexed arbiter,
        uint256 amount,
        uint256 arbiterCases,
        uint256 periodCases
    );

    /// A closed period's unclaimed remainder, pushed out to the foundation once
    /// the claim window lapsed. `periodCases` says WHY: zero means nobody could
    /// ever have claimed it, and a non-zero means people could and did not.
    /// Those two readings lead to opposite conclusions about the protocol and
    /// the log must not make them look alike.
    event PayrollRemainderSwept(
        uint256 indexed period,
        address indexed to,
        uint256 amount,
        uint256 periodCases
    );

    // ==========================================================
    //  MODIFIERS
    // ==========================================================

    /// Raw `msg.sender`, deliberately, and the same shape as every other
    /// owner check in the diamond: trusting the ERC-2771 tail in an ownership
    /// check hands ownership to the forwarder. Registered in
    /// script/gasless-sender.allow.
    modifier onlyOwner() {
        if (OwnershipLib.contractOwner() != msg.sender) revert NotOwner();
        _;
    }

    // ==========================================================
    //  THE PAYROLL POT
    // ==========================================================

    /// @notice Pay into the pot decision 69's stream fills and decision 73 pays out of.
    /// Open to the diamond owner and to the current `FactoryStorage.feeRecipient`
    /// — the same two as `fundVault`, for the same reason and with no separate
    /// treasury address to set.
    ///
    /// ⚠️ THE POT HAS NO SPENDER YET, and that is a fact about today rather
    /// than a defect of this function. Decision 69 fixes the SHAPE of the
    /// stream (a judicial-work counter admits, the period's actual workers
    /// share) and says the size is deliberately unset; nothing that pays an
    /// arbiter out of this pot has been written. Money paid in now therefore
    /// sits here until that facet is mounted.
    ///
    /// Unlike the same mistake in an immutable treasury, this one is
    /// recoverable — the pot is in a diamond and a cut can give it a door.
    ///
    /// ⚠️ AND THAT RECOVERABILITY IS WHY THE SHARE IS *NOT* HELD AT ZERO
    /// (decision 74, 4 September 2026, reversing what this docstring used to
    /// advise). The pot lives here, in the diamond — so decision 73's payout is
    /// an ordinary cut, not a treasury replacement. Filling a pot whose door is
    /// one cut away is not the same mistake as filling one in a contract that
    /// can never change.
    ///
    /// ⚠️ AND THE POT HAS A DOOR SINCE 25 SEPTEMBER 2026 (mainnet item D3), so
    /// the two paragraphs above are history and are kept as history. The payout is
    /// `bookPayrollShare` below: a CLOSED period's pot divided by the cases that
    /// stood in it. `test_TheStreamFillsAPotThatNowHasADoor` holds the inverted
    /// pair — the money arrives, and exactly one file under src/ subtracts from
    /// this balance. It went red on the day the payout landed, which is the
    /// handshake the old version of it swore to collect.
    ///
    /// The money is pulled with `transferFrom(msg.sender, …)` — the same raw
    /// address the role was checked against. If the check and the source ever
    /// disagreed, the forwarder would become the payer.
    function fundArbiterPayroll(uint256 amount) external {
        if (msg.sender != OwnershipLib.contractOwner()
            && msg.sender != FactoryStorage.store().feeRecipient) revert NotOwnerOrFeeRecipient();

        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        d.arbiterPayrollBalance += amount;

        // ── and into the period this transaction lands in ──────────────────
        //
        // ⚠️ THE MONEY IS STAMPED WITH THE PERIOD IT ARRIVED IN, AND THE STAMP
        // IS THE ANSWER TO "WHAT IF THE TREASURY IS LATE". A period closes on
        // the clock; the treasury's push is a separate transaction that may
        // land days afterwards. Money that arrives after the period closed goes
        // to the period it ARRIVED in, never back into the one that just ended
        // — and it has to be that way round, because a closed period's pot is
        // what its shares were computed from. Letting a late payment reopen it
        // would mean the second claimant divided a bigger pot than the first
        // did, and the sum of the shares could exceed the money there is.
        //
        // The cost of the choice, said out loud: work done in the last days of
        // a period is paid out of a pot the fees of those same days did not
        // reach. Over any run of periods the two even out; for one period they
        // do not, and no arrangement of one timestamp can make them.
        d.payrollPeriodPot[ArbiterRegistryStorage.currentPayrollPeriod()] += amount;

        emit ArbiterPayrollFunded(msg.sender, amount);
    }

    /// @notice What the payroll pot holds. The treasury reads it before and
    /// after a push and refuses the push if it did not grow by the amount sent,
    /// which is how a silently swallowed payment is caught rather than emitted
    /// as a success.
    ///
    /// A SEPARATE FIELD from `vaultBalance`, not a share of one number: the two
    /// pots are spent by different rules and one of them is not spendable yet.
    function getArbiterPayrollBalance() external view returns (uint256) {
        return ArbiterRegistryStorage.data().arbiterPayrollBalance;
    }

    // ==========================================================
    //  THE READABLE NUMBERS (decision 65)
    // ==========================================================

    /// @notice The vault's target, in USDC.
    ///
    /// ⚠️ STORED AS A NUMBER OF DISPUTES AND MULTIPLIED HERE. Decision 60 asks
    /// for the target to be expressed in disputes rather than dollars, because
    /// a dollar sum goes stale exactly the way the old treasury's frozen 500
    /// USDC did; the treasury's own header asks for the multiplication to
    /// happen on this side, because what one dispute costs is arbitration
    /// business logic and the treasury must not pretend to know it.
    ///
    /// The per-dispute cost is `getArbiterFloor()`, read back THROUGH THE
    /// DIAMOND rather than copied. A copy of `DEFAULT_ARBITER_FLOOR` here would
    /// be a second declaration of one number, and this repository has already
    /// paid for that shape: two values, a promise that they agree, and nothing
    /// that goes red when they diverge. The self-call routes to whichever facet
    /// answers `getArbiterFloor()` at the time, so the fallback for "never set"
    /// is applied in one place, not two.
    ///
    /// ⚠️ THE SEAM THIS OPENS, NAMED: `setArbiterFloor` now moves the vault
    /// target too. That is the intent of decision 60 — a target that tracks what
    /// a dispute actually costs — and not a side effect, but whoever raises the
    /// floor is raising the target with it. What bounds the result is not here:
    /// the treasury clamps whatever it reads to its own frozen
    /// `VAULT_TARGET_MAX`.
    ///
    /// SATURATES rather than reverting on an absurd dispute count. Overflow
    /// would make this view revert, the treasury would read the failure as
    /// zero, and the vault would silently stop being topped up. Saturation
    /// hands the treasury a number above its ceiling, which its clamp already
    /// handles — and it grants nobody anything, since the same clamped result
    /// is reachable with an ordinary count.
    function getVaultTarget() external view returns (uint256) {
        return _vaultTarget();
    }

    /// The same number, for the callers inside this facet. ⚠️ A THIN WRAPPER AND
    /// NOT A SECOND COPY: `getVaultTarget()` above is what the treasury reads
    /// and `pushVaultSurplus` below is what spends against it, and they are
    /// required to be the same arithmetic — not two subtractions that agree
    /// today. Kept internal rather than letting the door self-call the diamond:
    /// the formula lives in this contract, so routing a call through the proxy to
    /// reach it would buy nothing and could be unmounted from under it.
    function _vaultTarget() internal view returns (uint256) {
        uint256 disputes = ArbiterRegistryStorage.data().vaultTargetDisputes;
        if (disputes == 0) return 0;

        uint256 floor_ = ArbiterVaultFacet(address(this)).getArbiterFloor();
        if (floor_ == 0) return 0;

        unchecked {
            uint256 target = disputes * floor_;
            if (target / floor_ != disputes) return type(uint256).max;
            return target;
        }
    }

    /// @notice The target as it is STORED — a count of disputes. Without this
    /// there is no way to tell whether `getVaultTarget()` moved because the
    /// count moved or because the arbiter floor did, and no way for whoever set
    /// the count to read back what he set.
    function getVaultTargetDisputes() external view returns (uint256) {
        return ArbiterRegistryStorage.data().vaultTargetDisputes;
    }

    /// @notice The arbiter vault's share of treasury income, in basis points.
    /// Bounded here only by the whole; the treasury clamps it again to its own
    /// frozen `VAULT_BPS_MAX`, and that clamp is the one that is a promise.
    function getTreasuryVaultBps() external view returns (uint256) {
        return ArbiterRegistryStorage.data().treasuryVaultBps;
    }

    /// @notice The arbiter payroll stream's share of treasury income, in basis
    /// points. Decision 69 leaves the size deliberately unset; zero here is the
    /// honest answer until it is decided, and it also keeps the treasury from
    /// filling a pot that has no door yet.
    function getTreasuryPayrollBps() external view returns (uint256) {
        return ArbiterRegistryStorage.data().treasuryPayrollBps;
    }

    /// @notice The foundation's share of treasury income, in basis points.
    ///
    /// ⚠️ THE ONLY ONE OF THE THREE WHOSE CEILING MOVES, and it moves in the
    /// treasury, not here: on the governance handover the treasury drops the
    /// ceiling from FOUNDATION_BPS_MAX to FOUNDATION_BPS_MAX_DAO and remembers
    /// that it did. Nothing in this facet can lift it back, which is the whole
    /// point of the value being read here and the bound being frozen there.
    function getTreasuryFoundationBps() external view returns (uint256) {
        return ArbiterRegistryStorage.data().treasuryFoundationBps;
    }

    // ==========================================================
    //  SETTERS — the owner's, and only the owner's
    // ==========================================================

    /// @notice Move all three shares at once.
    ///
    /// ⚠️ ONE SETTER AND NOT THREE, on purpose. The treasury's own header says
    /// it in as many words: the three ceilings are ONE decision, because they
    /// are shares of the same base and what they leave over is the reserve's
    /// floor. Three separate setters would mean three transactions with two
    /// intermediate states in between, each of which is a real split that a
    /// distribution can land in the middle of. It also gives the cut ONE call
    /// to make the numbers live in the same transaction that mounts them.
    ///
    /// The sum is bounded by the whole here as well as in the treasury. That
    /// bound is not a promise — this facet is replaceable and the treasury's
    /// clamps already make an over-100% split unreachable in the ladder — it is
    /// what makes the three numbers mean what they say to anyone reading them
    /// off the chain.
    function setTreasuryShares(
        uint256 vaultBps,
        uint256 payrollBps,
        uint256 foundationBps
    ) external onlyOwner {
        // Checked one at a time first, so that the sum below cannot itself
        // overflow and answer a deliberate `type(uint256).max` with a panic
        // instead of a named refusal.
        if (vaultBps > BPS || payrollBps > BPS || foundationBps > BPS) revert ShareAboveWhole();
        if (vaultBps + payrollBps + foundationBps > BPS) revert SharesExceedWhole();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        d.treasuryVaultBps      = vaultBps;
        d.treasuryPayrollBps    = payrollBps;
        d.treasuryFoundationBps = foundationBps;

        emit TreasurySharesUpdated(vaultBps, payrollBps, foundationBps);
    }

    /// @notice How many disputes the vault should be able to cover.
    /// Zero means "no target", which the treasury reads as "nothing to top up"
    /// and skips the vault rung entirely — the state of a freshly cut diamond,
    /// and the reason the cut must carry this call.
    function setVaultTargetDisputes(uint256 disputes) external onlyOwner {
        ArbiterRegistryStorage.data().vaultTargetDisputes = disputes;
        emit VaultTargetDisputesUpdated(disputes);
    }

    // ==========================================================
    //  THE ARBITER BANK'S DOOR OUT (24 September 2026, item D2)
    // ==========================================================

    /// @notice Push whatever the arbiter bank holds ABOVE its target out to the
    /// foundation the treasury already pays.
    ///
    /// ⚠️ WHY IT EXISTS (the owner's decision of 24 September 2026, mainnet
    /// item D2). The bank had exactly one way out and it was not a way out: a
    /// discount of at most three dollars on a top-up in a SMALL dispute, paid
    /// only if a party chooses to top up. That waits on an event which may never
    /// happen — no small dispute, no spend — and by the owner's money rule a pot
    /// whose only exit waits on an event that may never happen is a dead end,
    /// however small.
    ///
    /// ⚠️ AND THE TARGET DOES NOT HOLD THE BANK DOWN, which is why this door is
    /// not decoration. The target throttles ONE inflow, the treasury's own
    /// stream, through `vaultRoom()` on the treasury side. Six places write
    /// `vaultBalance` and not one of them asks the target:
    /// `ArbiterVaultFacet._settleForfeitedShare` and `.fundVault`,
    /// `ArbiterAccountabilityFacet._performRemoval` (a removed arbiter's seat
    /// bond), `ArbiterRegistryFacet` twice where the bank's dispute subsidy comes
    /// back, and the remainder of dividing an appeal deposit among its panel. The
    /// bank can therefore stand above its target, and before this door nothing
    /// could bring it back down.
    ///
    /// ⚠️⚠️ PART OF THIS MONEY IS PENALTY MONEY, AND SENDING IT TO THE
    /// FOUNDATION IS A DECISION RATHER THAN PLUMBING. Two of those six inflows
    /// are fines: the 80% of a dispute fee forfeited by an arbiter whose verdict
    /// was overturned, and the seat bond of an arbiter removed for cause (that
    /// second door is retired at the entrance — `postArbiterBond` reverts
    /// `SeatBondRetired` — so it can only be non-zero on a diamond that held such
    /// a bond before, but the code path is live). A third, the remainder of an
    /// appeal deposit's division, is somebody's own money left over by integer
    /// division. So the route this door opens is "fines and leftovers -> the
    /// foundation", and it is written here in as many words because it is the
    /// sort of thing that gets built as a detail and discovered as a policy. The
    /// owner decided it on 24 September 2026, the working journal carries the
    /// entry, and no public page says it until he says so.
    ///
    /// ── WHY THE FOUNDATION AND NOT A NEW ADDRESS ──────────────────────────
    /// It is the one place money already leaves this protocol lawfully: the
    /// treasury pays it a share of every distribution. Sending the surplus there
    /// introduces NO new address and NO new trusted party. The alternative on the
    /// table — pouring it into the arbiter payroll pot two functions above — was
    /// rejected by the owner the same day, because that pot has no door at all:
    /// it would move money from one dead end into another.
    ///
    /// ── WHY IT LIVES ON THIS FACET AND NOT ON ArbiterVaultFacet ───────────
    /// The vault facet is where the bank's other doors are, and its own header
    /// claims every door that only moves money. Two things decided against it,
    /// and the second was measured rather than argued.
    ///
    ///   1. THE TARGET IS DECLARED HERE. On the vault facet the door would have
    ///      to reach `getVaultTarget()` back through the diamond, which means a
    ///      second declaration of that signature in a local interface (the
    ///      concrete type cannot be imported: the cycle makes solc 0.8.31 with
    ///      `via_ir` abort with an internal error, "Yul assertion failed",
    ///      EVMDialect.cpp:299 — measured on this tree, 24 September 2026). Here
    ///      it is one internal call to `_vaultTarget()` and no second spelling
    ///      of anything.
    ///   2. GROWING ArbiterVaultFacet COSTS 43 RED TESTS IN SEVEN STANDS
    ///      (measured, 24 September 2026, full run in the cage). That facet is a
    ///      named group in the Replace lists of already-signed, already-executed
    ///      cut scripts, and every one of those scripts' pre-flights asserts
    ///      "the compiled facet, less what this cut adds, is exactly what this
    ///      cut replaces". Two of the seven stands cannot be satisfied by any
    ///      test-side allowance: the `Replace` those pre-flights build would be
    ///      aimed at selectors the rehearsal rig does not route. Satisfying them
    ///      would mean editing signed scripts, which this repository does not do.
    ///      This facet is a group in no signed script's Replace list.
    ///
    /// The line "the vault facet takes every door that only moves money" is
    /// already crossed on this side: `fundArbiterPayroll` above moves USDC and
    /// writes the same `ArbiterRegistryStorage`.
    ///
    /// ── THE SHAPE, COPIED FROM `ArbiterVaultFacet.withdrawTreasurySlice` ───
    ///   * `external`, no owner gate: ANYBODY may press it. A door that waits on
    ///     the owner remembering it is not an exit — it waits on an event that may
    ///     never happen, which is the very defect being repaired.
    ///   * the recipient comes from the chain, never from an argument. The presser
    ///     chooses nothing but the moment, so his right to press decides nothing.
    ///     This function takes no parameters at all, and
    ///     `test/ArbiterVaultSurplusDoor.t.sol` pins that against the COMPILED
    ///     ABI rather than against a hand-typed copy of the signature.
    ///   * a named refusal when there is nothing to move, so the honest "no" never
    ///     looks like a transfer of zero.
    ///
    /// ── THE RECIPIENT, AND THE LINK IT TRAVELS ────────────────────────────
    /// `FactoryStorage.feeRecipient` IS the treasury — that is what installing a
    /// treasury means here, and it is why `fundArbiterPayroll` grants it the same
    /// right — and the treasury holds the foundation address in an `immutable`
    /// with no setter. So this door asks the treasury, at the moment of the press,
    /// where the foundation is. Two hops and no copy: a foundation address stored
    /// in the diamond as well would be a second declaration of one address, and
    /// replacing the treasury would leave the two disagreeing with nothing going
    /// red.
    ///
    /// Nothing here checks that the fee recipient is the treasury bound to THIS
    /// diamond, and that is deliberate rather than overlooked: `setFeeRecipient`
    /// already redirects every dollar of fee income, so a second read would
    /// constrain the owner in nothing while adding a way for this door to jam.
    ///
    /// ── THE SURPLUS IS MEASURED ABOVE THE DEBTS, NOT ABOVE THE BALANCE ────
    /// `bankAboveDebts`, the same reading every other spend of the bank has used
    /// since 17 September 2026. An appellant owed money by a settled appeal is
    /// paid out of this bank by `settleAppealDebts`, and his money must not leave
    /// as somebody's surplus — that would not close a dead end, it would open a
    /// worse one. `test/AppealEconomics.t.sol`
    /// (`test_AStandingAppealDebtIsNotSurplus`) is the scene, on the only rig in
    /// this repository that can produce a standing debt.
    ///
    /// ── WHAT A PRESS AT A BAD MOMENT COSTS ────────────────────────────────
    /// Nothing to anybody but the presser. With a surplus of one base unit the
    /// press moves one base unit to the foundation and burns the presser's own
    /// gas; there is no minimum, because a minimum would make dust the one thing
    /// that can never leave — a dead end again, smaller. Nobody else's balance can
    /// be moved by pressing it, and the target always stays behind.
    ///
    /// ── GASLESS: THERE IS NOTHING HERE TO RELAY ───────────────────────────
    /// The project's rule is that everything a person does has a gasless path.
    /// This door reads NO sender at all — neither `_msgSender()` nor `msg.sender`
    /// — so there is nothing about it for ERC-2771 to carry: any wallet, or the
    /// relayer's own key, may press it and the outcome is identical.
    /// `withdrawTreasurySlice`, the door this one is copied from, is the same;
    /// what makes THAT one actually get pressed is not a forwarder but two things
    /// outside the contracts — a button on the admin screen and
    /// `runTreasurySliceKeeper()` in `relayer/app.js`.
    ///
    /// ⚠️ THIS DOOR HAS NEITHER YET (measured 24 September 2026). Until a presser
    /// exists it is open and unpressed, which is exactly the state the treasury
    /// slice sat in for its first forty-five days while a comment claimed a keeper
    /// pushed it.
    ///
    /// ── IF THE TOKEN REFUSES ──────────────────────────────────────────────
    /// HARD `require`, not a soft catch: the whole call reverts and the bank is
    /// exactly as it was. There is no addressee to book the money to instead — the
    /// foundation is not a party that can come and collect from a
    /// `refundableBounty` — so the only honest outcome of a refused transfer is
    /// that nothing happened. Compare `withdrawDisputeBounty`, where a soft refund
    /// IS right because the money has an owner who can return for it.
    function pushVaultSurplus() external {
        uint256 target = _vaultTarget();
        // ⚠️ ZERO IS A REFUSAL. See `VaultTargetUnset`.
        if (target == 0) revert VaultTargetUnset();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        uint256 spendable = ArbiterRegistryStorage.bankAboveDebts(d);
        if (spendable <= target) revert NoVaultSurplus();
        uint256 surplus = spendable - target;

        address to = _foundationAddress();

        d.vaultBalance -= surplus;

        bool ok = IUSDCFull(FactoryStorage.store().usdc).transfer(to, surplus);
        require(ok, "TreasuryLink: vault surplus transfer failed");

        emit VaultSurplusPushed(to, surplus, target);
    }

    /// @notice What `pushVaultSurplus` would move if it were pressed right now.
    ///
    /// Zero whenever that door would REFUSE — including when the target reads
    /// zero, which is the one case a reader is most likely to get backwards. A
    /// keeper or a screen presses only on a non-zero answer here, and therefore
    /// never has to carry its own copy of the subtraction: the arithmetic is
    /// declared once, in the door, and quoted once, here.
    function getVaultSurplus() external view returns (uint256) {
        uint256 target = _vaultTarget();
        if (target == 0) return 0;
        uint256 spendable = ArbiterRegistryStorage.bankAboveDebts(ArbiterRegistryStorage.data());
        return spendable > target ? spendable - target : 0;
    }

    // ==========================================================
    //  THE PAYROLL POT'S DOOR OUT (25 September 2026, mainnet item D3)
    // ==========================================================
    //
    // The pot has had an inlet since 4 September 2026 — a fifth of every
    // treasury distribution — and until this block it had no outlet of any kind.
    // `TreasuryLinkUpgrade`'s appointed lock was green on that fact and named this
    // branch as the handshake that would come to collect. It did: the lock went
    // red, and its assertion is now the inversion rather than a widening.
    //
    // ── WHAT AN ARBITER IS PAID, AND WHY IT IS NOT A WAGE ─────────────────
    //
    // The owner's decision of 25 September 2026: pay it as a PERCENTAGE and not
    // as a fixed sum. So there is no salary here and no per-case price. There is
    // a period, the money that arrived in it, and the work that closed in it:
    //
    //     share = the period's pot × his cases that stood ÷ all cases that stood
    //
    // Nothing about that fraction needs to know what a case is worth, which is
    // the point: a fixed figure would have to be guessed now, would be wrong at
    // every volume but one, and would need the owner's hand to move — the very
    // kind of number decision 65 spent a whole treasury getting rid of.
    //
    // ── ⚠️ WHO IS BEING PAID TODAY, SAID OUT LOUD ────────────────────────
    //
    // There are FOUR arbiters, and every one of them was seated by hand by the
    // owner (`addArbiter`, `onlyOwnerOrChief`; measured on Base Sepolia,
    // 25 September 2026: `getArbiters()` returns four). So the first money this
    // door ever pays goes to people the owner chose, and possibly to the owner.
    // That is not a defect — somebody has to judge the first disputes, and
    // decision of 1 August 2026 says the corps starts hand-picked on purpose —
    // but it must not be left to be discovered from a block explorer. It is the
    // same disclosure the route "fines and leftovers → the foundation" carries
    // in `pushVaultSurplus` above.
    //
    // A second number belongs beside it: on 25 September 2026 the live diamond
    // had closed ZERO disputes cleanly in its entire life (`cleanDisputesTotal`,
    // read off the chain). Today this door would refuse every period for want of
    // a denominator. What it changes today is the SHAPE, not the sum.
    //
    // ── ⚠️ AND WHAT THIS DOOR DOES NOT DEFEND AGAINST ────────────────────
    //
    // Counting only verdicts that STOOD keeps the pot from paying for work the
    // appeal panel had to undo. It does NOT keep an arbiter from manufacturing
    // work. Opening a dispute is free (81 431 gas, no USDC — measured), a deal
    // between two addresses one person holds costs only the protocol fee, and a
    // verdict nobody appeals is "clean" by every measure this repository has. So
    // an arbiter with a second wallet can buy cases cheaply and grow his share
    // of a period's pot with them. NOTHING HERE STOPS THAT, and no test in this
    // branch claims otherwise. What bounds it today is that a seat is granted by
    // hand; what would bound it after seats open is a cap on one arbiter's share
    // of one period, which is a POLICY and therefore the owner's to set, not
    // this file's to invent. Written up as an open item on the day this door
    // landed.

    /// @notice Book `arbiter`'s share of a CLOSED period's payroll pot.
    ///
    /// ⚠️ IT BOOKS; IT DOES NOT PAY. The share lands in `arbiterRewards`, the
    /// same claimable balance a won dispute's bounty lands in, and the arbiter
    /// takes it out of the diamond with `withdrawArbiterReward()` — a door that
    /// already exists, already reads `_msgSender()` so it works through the
    /// relayer, and is already on the arbiter's screen. Paying USDC straight out
    /// of here would have meant a second withdrawal path for the same person's
    /// money and a second `_msgSender()` in a facet that reads no sender at all.
    ///
    /// ⚠️ ANYBODY MAY PRESS IT, AND IT IS STILL A PULL IN THE ONLY SENSE THAT
    /// COSTS ANYTHING. What the "no push" rule forbids is a pass over the whole
    /// corps, whose gas grows with the number of arbiters until one day it does
    /// not fit in a block. This call touches ONE arbiter and ONE period: its
    /// cost is flat however large the corps grows. Leaving the press to the
    /// arbiter alone would have bought nothing — the recipient is not a
    /// parameter in any meaningful sense, since the only addresses this function
    /// can pay are the ones storage already records as having judged in that
    /// period, and the amount is fixed by storage too. A stranger pressing it
    /// can move the money to its owner, sooner, at his own gas expense. He
    /// cannot move it anywhere else.
    ///
    /// ⚠️ AND THAT IS WHY THE REMAINDER DOOR BELOW TAKES NO ADDRESS. There the
    /// money goes to the protocol's own foundation, so an address argument would
    /// let the presser choose where protocol money lands. Here the argument only
    /// selects among people the chain has already credited. The two look like the
    /// same shape and are not, and the difference is held by
    /// `test_ThePresserOfTheRemainderDoesNotChooseTheRecipient`.
    ///
    /// @param period  the payroll period, `timestamp / 30 days`. Must be over.
    /// @param arbiter whose cases are being paid for.
    function bookPayrollShare(uint256 period, address arbiter) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        // ⚠️ THE PERIOD MUST BE OVER, and this is the line that makes every
        // share below safe to compute. While a period is current both sides of
        // the fraction still move: a later case shrinks everyone's share, and a
        // later payment grows it. Booking inside an open period would let the
        // first claimant take a share of a pot the last case had not been
        // divided into yet, and the sum of the shares would exceed the pot.
        if (period >= ArbiterRegistryStorage.currentPayrollPeriod()) revert PayrollPeriodOpen();

        // Named separately from "you have no share", and never reached as a
        // division by zero. See `PayrollPeriodHasNoCases`.
        uint256 periodCases = d.payrollPeriodCases[period];
        if (periodCases == 0) revert PayrollPeriodHasNoCases();

        // ⚠️ THE AMOUNT IS ASKED OF THE QUOTE'S OWN FUNCTION AND NOT COMPUTED
        // HERE. `payrollShareOf` is what `quotePayrollShare` answers with, so a
        // screen or a keeper that presses only on a non-zero quote can never be
        // offering a press the chain will refuse, and there is exactly one
        // division in the tree instead of two that promise to agree. It returns
        // zero for every reason this door refuses: already booked, no case of
        // his, a period already settled by the remainder door, or a pot so small
        // that his fraction of it rounds to nothing.
        //
        // ⚠️ FLOOR DIVISION, AND WHAT IT DROPS STAYS IN THE POT. Rounding up
        // would let the last claimants take more than there is; spreading the
        // remainder would need a pass over the corps, which is the thing this
        // design refuses to have. The few base units go out of the remainder
        // door with the rest — `test_TheDivisionRemainderLeavesWithTheSweepAndIsNotLost`
        // names the sum to the base unit.
        uint256 share = ArbiterRegistryStorage.payrollShareOf(d, period, arbiter);
        if (share == 0) revert NoPayrollShare();

        // For the log only: the numerator the amount above was computed from.
        uint256 mine = d.payrollPeriodCasesBy[period][arbiter];

        d.payrollShareBooked[period][arbiter] = true;
        d.payrollPeriodBooked[period] += share;
        // The two halves of one movement. `arbiterPayrollBalance` is the pot's
        // total and `arbiterRewards` is the arbiter's claim; both are terms of
        // the balance identity in test/DiamondLedgerIdentity.t.sol, so moving
        // between them keeps `USDC.balanceOf(diamond)` equal to the sum, and
        // forgetting either half makes it disagree by exactly this share.
        d.arbiterPayrollBalance -= share;
        d.arbiterRewards[arbiter] += share;

        emit PayrollShareBooked(period, arbiter, share, mine, periodCases);
    }

    /// @notice Push a lapsed period's unclaimed remainder out to the foundation.
    ///
    /// ⚠️ THE POT MUST HAVE AN EXIT OR IT IS A SECOND DEAD END, and that is the
    /// whole reason this function exists. A period whose arbiters never came —
    /// or, far more likely on today's numbers, a period in which nobody judged
    /// anything at all — would otherwise hold its money for ever, and mainnet
    /// item D3 would have been closed by opening a smaller version of itself.
    ///
    /// The shape is the one already accepted for the arbiter bank
    /// (`pushVaultSurplus` above), the treasury slice
    /// (`ArbiterVaultFacet.withdrawTreasurySlice`) and the treasury's reserve
    /// (`ProtocolTreasury.releaseReserveToFoundation`): OPEN TO ANYBODY, so it
    /// does not wait on the owner remembering it; the RECIPIENT READ OFF THE
    /// CHAIN, so pressing decides nothing; and the DEADLINE IN A CONSTANT, so it
    /// is not a lever either.
    ///
    /// ⚠️ IT IS THE LAST RESORT AND NOT THE ROAD. Today it is the only branch
    /// that can ever fire — zero clean disputes have closed on the live diamond
    /// — which means the length of `PAYROLL_CLAIM_WINDOW` decides how much of
    /// the arbiters' twenty per cent ends up as foundation money. That number is
    /// a proposal at one year and is flagged for the owner where it is declared.
    ///
    /// ── IF THE TOKEN REFUSES ──────────────────────────────────────────────
    /// Hard `require`, exactly as in `pushVaultSurplus`, and for the same
    /// reason: the foundation is not a party that can come back for a booked
    /// refund, so the only honest outcome of a refused transfer is that nothing
    /// happened at all.
    function sweepPayrollPeriod(uint256 period) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        // One condition, not two: the sweep time already implies the period is
        // over, since it is measured from the period's own end. Asking
        // `PayrollPeriodOpen()` here as well would be a second rule that agrees
        // with the first today and could stop agreeing.
        if (block.timestamp < ArbiterRegistryStorage.payrollSweepableAt(period)) {
            revert PayrollPeriodNotLapsed();
        }

        uint256 pot = d.payrollPeriodPot[period];
        uint256 left = pot - d.payrollPeriodBooked[period];
        if (left == 0) revert NoPayrollRemainder();

        address to = _foundationAddress();

        // The period is settled: nothing may be booked out of it afterwards.
        // Written as the pot's whole size rather than `+= left`, so a period
        // swept twice is stopped by `left == 0` above and not by arithmetic.
        d.payrollPeriodBooked[period] = pot;
        d.arbiterPayrollBalance -= left;

        bool ok = IUSDCFull(FactoryStorage.store().usdc).transfer(to, left);
        require(ok, "TreasuryLink: payroll remainder transfer failed");

        emit PayrollRemainderSwept(period, to, left, d.payrollPeriodCases[period]);
    }

    /// @notice What `bookPayrollShare(period, arbiter)` would book right now.
    ///
    /// Zero for every reason that door would refuse, so a screen or a keeper
    /// that presses only on a non-zero answer never needs its own copy of the
    /// division. ⚠️ It does NOT encode "the period is over": a caller asking
    /// about the current period gets the share as it stands at this second,
    /// which is the honest answer to "what am I owed so far" and would be a lie
    /// dressed as a promise if it were rounded to zero.
    function quotePayrollShare(uint256 period, address arbiter) external view returns (uint256) {
        return ArbiterRegistryStorage.payrollShareOf(ArbiterRegistryStorage.data(), period, arbiter);
    }

    /// @notice The period a transaction landing now belongs to, and the second
    /// it ends at.
    ///
    /// Both, from one call: a screen that has to show "this period closes in
    /// four days" would otherwise carry its own copy of the period length, and a
    /// copy of that number is the seam this facet's constants block refuses to
    /// open.
    function getPayrollPeriod() external view returns (uint256 period, uint256 endsAt) {
        period = ArbiterRegistryStorage.currentPayrollPeriod();
        endsAt = (period + 1) * ArbiterRegistryStorage.PAYROLL_PERIOD;
    }

    /// @notice Everything about one period, in one read: what arrived in it,
    /// what has left it, how many cases divide it, and when its remainder may be
    /// pushed out.
    ///
    /// `pot` is frozen once the period ends and `booked` is what has gone, so
    /// `pot - booked` is what is still there. A reader wanting one arbiter's
    /// number asks `quotePayrollShare`; this is the denominator's side.
    function getPayrollPeriodStatus(uint256 period)
        external
        view
        returns (uint256 pot, uint256 booked, uint256 cases, uint256 sweepableAt)
    {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        pot         = d.payrollPeriodPot[period];
        booked      = d.payrollPeriodBooked[period];
        cases       = d.payrollPeriodCases[period];
        sweepableAt = ArbiterRegistryStorage.payrollSweepableAt(period);
    }

    /// Where the surplus goes: the foundation, read off the treasury the diamond
    /// already pays its fees to.
    ///
    /// A raw `staticcall` and not a typed interface, because the answer must be
    /// allowed to be ABSENT. A fee recipient that is an ordinary wallet — which
    /// it was before the treasury was installed, and which it becomes again if
    /// the treasury is ever replaced by one — has no `foundation()` at all, and a
    /// staticcall to a wallet SUCCEEDS with empty returndata. That empty answer
    /// must become a named refusal rather than the zero address.
    ///
    /// The word is decoded as a `uint256` and narrowed by hand instead of
    /// `abi.decode(data, (address))`: decoding an address panics on a word with
    /// dirty high bytes, and a panic here would tell whoever pressed the door
    /// nothing about what is wrong.
    function _foundationAddress() private view returns (address) {
        address recipient = FactoryStorage.store().feeRecipient;
        if (recipient == address(0)) revert FoundationUnreachable();

        (bool ok, bytes memory data) = recipient.staticcall(abi.encodeWithSignature("foundation()"));
        if (!ok || data.length != 32) revert FoundationUnreachable();

        uint256 word = abi.decode(data, (uint256));
        if (word >> 160 != 0) revert FoundationUnreachable();

        address foundation = address(uint160(word));
        if (foundation == address(0)) revert FoundationUnreachable();
        return foundation;
    }
}
