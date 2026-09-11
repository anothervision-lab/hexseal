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

    // ==========================================================
    //  EVENTS
    // ==========================================================

    event ArbiterPayrollFunded(address indexed from, uint256 amount);
    event TreasurySharesUpdated(uint256 vaultBps, uint256 payrollBps, uint256 foundationBps);
    event VaultTargetDisputesUpdated(uint256 disputes);

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
    /// `test_TheStreamFillsAPotThatStillHasNoDoor` holds both halves: the money
    /// arrives, and no file under src/ subtracts from this balance. The second
    /// half MUST go red on the day the payout is written — that is the
    /// handshake with whoever writes it.
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

        ArbiterRegistryStorage.data().arbiterPayrollBalance += amount;
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
        uint256 disputes = ArbiterRegistryStorage.data().vaultTargetDisputes;
        if (disputes == 0) return 0;

        uint256 floor_ = ArbiterRegistryFacet(address(this)).getArbiterFloor();
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
}
