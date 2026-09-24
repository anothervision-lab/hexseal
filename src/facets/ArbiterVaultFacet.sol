// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ArbiterVaultFacet.sol
//
// The arbiter branch's MONEY and its PLAIN READS, carved out of
// ArbiterRegistryFacet on 16 September 2026.
//
// ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────
// Measured on a clean tree at 1e56aba5 with `forge build --sizes`:
// ArbiterRegistryFacet stood at 24 532 bytes against the EIP-170 limit of
// 24 576 — FORTY-FOUR BYTES of room, and one average external function of this
// repository costs about 220 of them. The appeal economics the owner approved
// (a deposit priced by floor and percentage, the panel paid, the refund
// charged to the arbiter who was wrong, a sagging seat that does not vote)
// could not be written at all: not "would be tight", but would not compile
// into a deployable contract.
//
// ── WHERE THE LINE RUNS ───────────────────────────────────────────────────
// One sentence: THE REGISTRY KEEPS EVERY DOOR THAT DECIDES A DISPUTE OR
// CHANGES WHO IS AN ARBITER; THIS FACET TAKES EVERY DOOR THAT ONLY MOVES
// MONEY AND EVERY DOOR THAT ONLY READS A NUMBER.
//
// The line was chosen by measurement, not by taste. Four candidate cuts were
// compiled, each one being the same facet with that group deleted
// (`forge build --sizes`, solc 0.8.31, via-ir, optimizer 200):
//
//   candidate                                    facet after   freed
//   the money group (17 doors)                      20 676      3 856
//   the appeal group (7 doors)                      21 016      3 516
//   the DAO group (7 doors)                         23 536        996
//   the plain readers (18 doors)                    22 533      1 999
//   money + the plain state readers  ← THIS FILE    19 205      5 327
//
// The appeal group frees a comparable number and is where the growth is
// coming, which is why it was considered first and rejected: `resolveAppeal`
// calls four helpers that the registry keeps for other callers —
// `_recordArbiterMistake` (also `overturnVerdict`, `notifyArbiterTimeout`),
// `_slashArbiterXP` (also `overturnVerdict`), `_hasLiveProposalHere` (also
// `resignAsArbiter` through `_requireNoLiveRemovalProposal`) and
// `_softTransfer` (also `clearDisputeClaim`). Moving the appeal means a second
// copy of the rules that suspend an arbiter and record an accusation, in a
// second file, with nothing that goes red when the two drift. The money group
// shares exactly ONE helper with what stays — `_msgSender`, eight lines of
// ERC-2771 boilerplate that every facet in this repository already declares
// for itself.
//
// ── WHAT DID NOT COME ALONG, AND WHY ──────────────────────────────────────
// The five CONSTANT getters stayed in the registry: getMinXPToRegister,
// getDaoThreshold, getMaxArbiterMistakes, getNoResponseFloor,
// getMaxClaimsPerArbiter. Each reads a private constant that the code left
// behind still applies (applyAsArbiter, activateDAO, _recordArbiterMistake,
// recordNoResponse, claimDispute), so moving the getter would mean a SECOND
// DECLARATION of the number here — the outside answered by a mirror while the
// live rule applies the original. That is the same reasoning the 16 August
// split wrote down for the same five, and it is worth about 555 bytes, which
// is not worth a mirror. The three constants that DID come along
// (ARBITER_SHARE_BPS, DEFAULT_ARBITER_FLOOR, DEFAULT_DISPUTE_DISCOUNT) have no
// reader left in the registry at all — measured, not assumed.
//
// isDaoActive and getChiefBloc stayed for the older reason: they are called
// from inside the registry (the onlyOwnerOrChief modifier; the private
// _chiefBloc that addArbiter holds).
//
// ── STORAGE IS THE SAME MEMORY, NOT A COPY ────────────────────────────────
// This facet declares NO storage of its own. Every read and write below goes
// through `ArbiterRegistryStorage.data()`, the library declared in
// ArbiterRegistryFacet.sol, which resolves to the fixed ERC-7201 slot
// 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00. A facet
// of a diamond runs by DELEGATECALL, so the storage it touches is the
// PROXY's, and two facets reading the same constant slot read the same bytes.
// That is why `fundVault` here and `finalizeVerdict` in the registry see one
// `vaultBalance`, and why nothing about this move needs a migration.
//
// ⚠️ A struct declared here instead would compile, deploy, and quietly read
// different bytes at the same offsets the moment the two declarations drift.
// The same class of error as the July 2026 termsHash→terms retype, and the
// reason there is exactly one declaration of `Data` in this repository.
//
// ── EVENTS AND ERRORS ARE THE REGISTRY'S, BY NAME ─────────────────────────
// Nothing below declares an event or an error of its own. They are emitted and
// reverted as `ArbiterRegistryFacet.X(...)` — ONE declaration, the same topic0,
// the same four-byte selector, no drift possible. The subgraph and the
// frontend see no difference: a log carries the DIAMOND's address as its
// emitter either way, because a facet never runs in its own context.
//
// ── ERC-2771 ──────────────────────────────────────────────────────────────
// `_msgSender()` below is the only sender this facet reads for anything a
// person does (fundDispute, withdrawDisputeBounty, withdrawArbiterReward). The
// bare `msg.sender` appears three times on purpose and only where the caller
// must be a CONTRACT or the owner — creditDisputeFee (the Agreement calls),
// fundVault and the onlyOwner modifier. That is the same split the registry
// uses; the class of bug it guards against is fundDispute reading msg.sender
// and seeing the forwarder (fixed in d172064, 31 July 2026).
// ============================================================

import "../../src/FactoryFacet.sol";          // FactoryStorage (trustedForwarder, usdc, feeRecipient)
import "../../src/DiamondProxy.sol";           // OwnershipLib
import "../RegistryFacet.sol";                 // RegistryStorage — who may credit a dispute fee
import {ArbiterRegistryStorage, ArbiterRegistryFacet, IUSDCFull} from "./ArbiterRegistryFacet.sol";

contract ArbiterVaultFacet {
    // -------- CONSTANTS --------
    //
    // All three moved here WHOLE: after the split the registry has no reader of
    // any of them left (measured on the tree, not assumed), so this is a move
    // and not a mirror. The registry's unread declarations of the same three
    // were only deleted on 17 September 2026; until then a front-end lock read
    // the dead copy instead of these.

    /// 90% of the dispute fee to the arbiter, the rest to the treasury.
    /// Read by `creditDisputeFee` (the actual booking) and by `_splitTopUp`
    /// (what the screen promises) — one declaration, so the promise and the
    /// booking cannot disagree.
    ///
    /// ⚠️ 80% UNTIL 22 SEPTEMBER 2026, when the owner raised it. The seat
    /// stopped being a place a man pays to sit in and became work he is paid
    /// for; the protocol's ten points of the fee are what it keeps for running
    /// the escrow, and the judge's ninety are what buy an hour of reading.
    /// Worked through on the pots the owner named: $500 pays $13.50, $2 000
    /// pays $54, $10 000 pays $270. Below about $110 the percentage cannot
    /// reach `arbiterFloor` at all and the dispute's opener makes up the
    /// difference — see `chargeDisputeOpening`.
    uint256 private constant ARBITER_SHARE_BPS = 9_000;

    /// 10 USDC (6 decimals) — what an arbiter must receive for a dispute in
    /// total while nobody has set `arbiterFloor`.
    uint256 private constant DEFAULT_ARBITER_FLOOR = 10_000_000;

    /// 3 USDC — what the vault takes off a top-up while nobody has set
    /// `disputeVaultDiscount`.
    uint256 private constant DEFAULT_DISPUTE_DISCOUNT = 3_000_000;

    // -------- MODIFIERS --------

    /// The same body as `ArbiterRegistryFacet.onlyOwner`, reverting the SAME
    /// error by name rather than a second declaration of it: a caller cannot
    /// tell which facet refused him, and should not have to.
    modifier onlyOwner() {
        if (OwnershipLib.contractOwner() != msg.sender) revert ArbiterRegistryFacet.NotOwner();
        _;
    }

    // -------- ERC-2771 SENDER --------

    /// Byte-for-byte the registry's `_msgSender`. It is duplicated rather than
    /// shared because it is the ONE thing a facet cannot borrow: it reads this
    /// call's own calldata. Every facet in this repository carries its own copy
    /// for the same reason, and script/check-gasless-sender.sh holds every
    /// .sol in src/ to having one or being written down with a reason.
    function _msgSender() internal view returns (address sender) {
        address forwarder = FactoryStorage.store().trustedForwarder;
        if (msg.sender == forwarder && msg.data.length >= 20) {
            assembly { sender := shr(96, calldataload(sub(calldatasize(), 20))) }
        } else {
            sender = msg.sender;
        }
    }

    // -------- REWARDS --------

    /// @notice The arbiter withdraws the reward that has piled up.
    function withdrawArbiterReward() external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        uint256 amount = d.arbiterRewards[caller];
        if (amount == 0) revert ArbiterRegistryFacet.NoRewardToClaim();

        d.arbiterRewards[caller] = 0;

        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transfer(caller, amount);
        require(ok, "ArbiterRegistry: USDC transfer failed");

        emit ArbiterRegistryFacet.ArbiterRewardWithdrawn(caller, amount);
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
            revert ArbiterRegistryFacet.NotRegisteredAgreement();
        if (total == 0) revert ArbiterRegistryFacet.ZeroAmount();

        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        ArbiterRegistryStorage.PendingVerdict storage v = d.pendingVerdicts[msg.sender];

        address arbiter_ = v.arbiter;
        // Nobody carried the dispute through to a verdict (submitVerdict was never
        // called) — there is nobody to credit, and staying silent is not an option:
        // money with no addressee would hang in the contract with no counter on it.
        if (arbiter_ == address(0)) revert ArbiterRegistryFacet.NoVerdictSubmitted();

        uint256 toArbiter = (total * ARBITER_SHARE_BPS) / 10_000;
        // By subtraction rather than a second share: that way no unit is lost
        // to rounding and the parts always add back up to the whole.
        uint256 toTreasury = total - toArbiter;

        if (v.overturned) {
            // The verdict was overturned (overturnVerdict/resolveAppeal) — the
            // arbiter was wrong and his 80% is withheld. Symmetrical with
            // finalizeVerdict, which on an overturn withholds the top-up too
            // and returns it to the payer through refundableBounty.
            //
            // ⚠️ THE TREASURY KEEPS ITS 20% AND NO MORE (17 September 2026,
            // the owner's decision; journal item 205). Until then the whole fee
            // went to the treasury on an overturn, so the protocol's own slice
            // GREW every time an arbiter was found wrong — and the appellant
            // who proved it was refunded his own deposit and nothing else. The
            // forfeited 80% now pays for the appeal that found the mistake and
            // whatever is left goes to the arbiter bank, never to the treasury.
            //
            // ⚠️ AND THE TREASURY'S 20% OF THIS SAME FEE IS THE SECOND SOURCE
            // (the owner's second decision, same day): it covers what the
            // arbiter's 80% and his bond left unpaid, before the bank does. It
            // keeps what that leaves — all of it in the ordinary case, where
            // the bond covered the refund.
            toTreasury = _settleForfeitedShare(d, msg.sender, arbiter_, v.appellant, toArbiter, toTreasury);
            toArbiter = 0;
        } else {
            d.arbiterRewards[arbiter_] += toArbiter;
        }
        d.treasurySlice += toTreasury;

        emit ArbiterRegistryFacet.DisputeFeeCredited(arbiter_, toArbiter, toTreasury);
    }

    /// The overturned arbiter's forfeited share, spent in the order the owner
    /// fixed on 17 September 2026:
    ///
    ///   1. what the appellant is still owed with nothing behind it (`debt`) —
    ///      booked into `refundableBounty`, because the share is real money
    ///      from this moment on and not before;
    ///   2. what the bank advanced to the appellant (`advanceFromVault`);
    ///   3. what the arbiter's own bond advanced (`advanceFromBond`) — back
    ///      into the bond while he still holds the seat, into the bank if he
    ///      does not (the only way to lose a seat while a verdict of his is in
    ///      flight is removal, and removal forfeits the bond into the bank:
    ///      restoring a forfeited bond to him would undo the forfeit);
    ///   4. the rest — into the arbiter bank.
    ///
    /// The bank is paid back BEFORE the bond on purpose: the arbiter was wrong,
    /// so what is left short at the end is his, not the shared buffer's.
    ///
    /// ⚠️ THEN THE TREASURY'S 20% OF THIS FEE (second decision, 17 September
    /// 2026). The full order of who bears a won appeal is the arbiter's share →
    /// his bond → the treasury's share of this fee → the bank → a debt. The
    /// bond's part was fixed when it advanced at `resolveAppeal`; so whatever
    /// the arbiter's share leaves of the DEBT and of the BANK'S advance is
    /// covered by the treasury's share next — the debt first, then the bank —
    /// and the treasury keeps the rest. It never gives the bond anything back:
    /// the bond stands before it in the order. It never pays for another deal:
    /// only this fee's 20%, and only after this fee's 80%.
    ///
    /// Returns what the treasury keeps.
    ///
    /// ⚠️ RUNS UNDER A HARD GAS CAP. The clone calls `creditDisputeFee` with
    /// exactly `Agreement.DISPUTE_FEE_GAS` (150 000) inside a try/catch, and a
    /// clone is pinned to its implementation for life, so that number cannot
    /// be raised for any deal that exists. Hence one packed ledger slot, no
    /// push transfer (the fee has not even arrived: the clone transfers it
    /// only after this call returns) and nothing that loops. Measured in
    /// test/AppealEconomics.t.sol against the cap, all storage cold.
    ///
    /// A plain verdict overturned by hand, with no appeal behind it, has an
    /// empty ledger and sends the whole 80% to the bank.
    function _settleForfeitedShare(
        ArbiterRegistryStorage.Data storage d,
        address agreement,
        address arbiter_,
        address appellant,
        uint256 share,
        uint256 levy
    ) private returns (uint256 treasuryKeeps) {
        ArbiterRegistryStorage.AppealLedger storage l = d.appealLedgers[agreement];
        uint256 debt       = l.debt;
        uint256 vaultOwed  = l.advanceFromVault;
        uint256 bondOwed   = l.advanceFromBond;

        // The arbiter's forfeited 80%: debt -> bank -> bond.
        uint256 toAppellant = debt < share ? debt : share;
        share -= toAppellant;
        uint256 vaultBack = vaultOwed < share ? vaultOwed : share;
        share -= vaultBack;
        uint256 bondBack = bondOwed < share ? bondOwed : share;
        share -= bondBack;

        // The treasury's 20% of this fee: what is still owed to the appellant,
        // then what the bank is still out. Never the bond.
        uint256 debtLeft = debt - toAppellant;
        uint256 levyToAppellant = debtLeft < levy ? debtLeft : levy;
        levy -= levyToAppellant;
        uint256 vaultLeft = vaultOwed - vaultBack;
        uint256 levyToVault = vaultLeft < levy ? vaultLeft : levy;
        treasuryKeeps = levy - levyToVault;
        uint256 fromTreasury = levyToAppellant + levyToVault;
        toAppellant += levyToAppellant;
        vaultBack   += levyToVault;

        if (toAppellant + vaultBack + bondBack != 0) {
            // uint64 cannot truncate: each is a remainder of one deposit.
            l.debt             = uint64(debt - toAppellant);
            l.advanceFromVault = uint64(vaultOwed - vaultBack);
            l.advanceFromBond  = uint64(bondOwed - bondBack);
        }

        if (toAppellant != 0) {
            d.refundableBounty[appellant] += toAppellant;
            d.appealDebtTotal -= toAppellant;
            emit ArbiterRegistryFacet.DisputeBountyRefundable(agreement, appellant, toAppellant);
        }

        uint256 toVault = vaultBack + share;
        uint256 toBond;
        if (bondBack != 0) {
            // ⚠️ BACK INTO THIS CASE'S OWN BOND (22 September 2026), which is
            // where the advance came from. It is handed to the arbiter a few
            // lines later in the same transaction: this call runs INSIDE
            // `finalizeVerdict`, and `_releaseCaseBond` there pays out whatever
            // is in the record once the escrow has moved.
            //
            // The record still exists here — nothing deletes it between the
            // advance and this line — but the address is checked all the same:
            // a zero there would send the money to nobody, and the bank is the
            // right place for money with no owner.
            ArbiterRegistryStorage.CaseBond storage cb = d.caseBonds[agreement];
            if (cb.arbiter != address(0)) {
                // uint96 cannot truncate: the sum is at most one deposit.
                cb.amount += uint96(bondBack);
                toBond = bondBack;
            } else {
                toVault += bondBack;
            }
        }
        if (toVault != 0) d.vaultBalance += toVault;

        emit ArbiterRegistryFacet.ForfeitedShareSpent(agreement, toAppellant, toBond, toVault, fromTreasury);
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
        if (slice == 0) revert ArbiterRegistryFacet.NothingToPush();

        d.treasurySlice = 0;

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        address recipient = fs.feeRecipient;
        bool ok = IUSDCFull(fs.usdc).transfer(recipient, slice);
        require(ok, "ArbiterRegistry: treasury slice transfer failed");

        emit ArbiterRegistryFacet.TreasurySlicePushed(recipient, slice);
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
            && msg.sender != FactoryStorage.store().feeRecipient) revert ArbiterRegistryFacet.NotOwnerOrFeeRecipient();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transferFrom(msg.sender, address(this), amount);
        require(ok, "ArbiterRegistry: USDC transfer failed");
        d.vaultBalance += amount;
        emit ArbiterRegistryFacet.VaultFunded(msg.sender, amount);
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
        revert ArbiterRegistryFacet.RewardPathRetired();
    }

    /// @notice How much the arbiter must receive for a dispute in total.
    /// A stored field rather than a constant: the right price of human time
    /// cannot be guessed in advance, and changing it later must cost one
    /// transaction, not an upgrade. It starts at 10 USDC.
    function setArbiterFloor(uint256 amount) external onlyOwner {
        ArbiterRegistryStorage.data().arbiterFloor = amount;
        emit ArbiterRegistryFacet.ArbiterFloorUpdated(amount);
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
        emit ArbiterRegistryFacet.DisputeDiscountUpdated(amount);
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
        if (rec.client == address(0)) revert ArbiterRegistryFacet.NotAuthorized();
        if (caller != rec.client && caller != rec.executor) revert ArbiterRegistryFacet.NotParty();

        if (d.disputeClaims[agreement] != address(0)) revert ArbiterRegistryFacet.DisputeAlreadyClaimed();
        if (d.disputeBounty[agreement] != 0) revert ArbiterRegistryFacet.BountyAlreadyFunded();

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
            revert ArbiterRegistryFacet.DisputeWindowPassed();
        }

        // gross is read, not what the person pays: a top-up is needed whenever
        // the arbiter falls short of the floor, regardless of how much of it the
        // vault took on. Checking the person's share would shut this door exactly
        // where the vault pays everything.
        if (gross == 0) revert ArbiterRegistryFacet.TopUpNotNeeded();

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

        emit ArbiterRegistryFacet.DisputeBountyFunded(agreement, caller, gross - subsidy, subsidy);
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
        if (amount == 0) revert ArbiterRegistryFacet.NoRefundableBounty();
        d.refundableBounty[caller] = 0;
        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transfer(caller, amount);
        require(ok, "ArbiterRegistry: bounty withdrawal failed");
        emit ArbiterRegistryFacet.DisputeBountyWithdrawn(caller, amount);
    }

    function getRefundableBounty(address who) external view returns (uint256) {
        return ArbiterRegistryStorage.data().refundableBounty[who];
    }

    // -------- THE BOND A CASE CARRIES: COLLECTING IT --------

    /// @notice The arbiter takes back the bond he put down for a case that
    /// ended without his verdict.
    ///
    /// ⚠️ WHY THIS DOOR EXISTS AT ALL, AND WHY THE MONEY IS NOT PUSHED. A
    /// case leaves an arbiter four ways: he finalizes it (and `finalizeVerdict`
    /// hands the bond straight back — no press needed, that is the ordinary
    /// ending), he lets go of it, a stranger abandons it for him, or the deal
    /// times out. The last three all end up inside `clearDisputeClaim` or
    /// beside it, and `clearDisputeClaim` is called BY THE CLONE under exactly
    /// CLAIM_CLEAR_GAS (200 000) inside an empty try/catch. A clone is pinned
    /// to its implementation for life, so that number can never be raised for a
    /// deal that already exists, and a refund on that path was measured at
    /// +46 000 gas — past the rig's 2x tripwire. Over the cap the catch
    /// swallows the whole call, including the release of the claim, and the
    /// arbiter is left holding a dispute for ever.
    ///
    /// So the money waits where it was booked and he comes for it. Gasless like
    /// every other claimable here.
    ///
    /// ⚠️ THE GATE IS "NOBODY IS JUDGING THIS DEAL", not a flag of its own. A
    /// live claim on the deal means the bond is still doing its job, whoever
    /// holds it; an empty `disputeClaims` means the case let go of him. The
    /// finalization path cannot be caught half-way: it clears the claim and
    /// pushes the bond inside ONE transaction, so there is no block in which
    /// this door could take the same money twice.
    function withdrawCaseBond(address agreement) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        ArbiterRegistryStorage.CaseBond memory b = d.caseBonds[agreement];
        if (b.amount == 0 || b.arbiter != caller) revert ArbiterRegistryFacet.NoRefundableBounty();
        if (d.disputeClaims[agreement] != address(0)) revert ArbiterRegistryFacet.DisputeAlreadyClaimed();

        delete d.caseBonds[agreement];
        address usdc = FactoryStorage.store().usdc;
        bool ok = IUSDCFull(usdc).transfer(caller, b.amount);
        require(ok, "ArbiterRegistry: case bond withdrawal failed");
        emit ArbiterRegistryFacet.CaseBondReturned(agreement, caller, b.amount);
    }

    /// @notice What this deal's bond holds and whose it is — the read a screen
    /// needs to show the button above, and the one a test asks instead of
    /// counting slots.
    function getCaseBond(address agreement) external view returns (uint256 amount, address arbiter) {
        ArbiterRegistryStorage.CaseBond memory b = ArbiterRegistryStorage.data().caseBonds[agreement];
        return (b.amount, b.arbiter);
    }

    /// @notice How many cases this arbiter is judging right now. One is the cap
    /// (`MAX_CASES_AT_ONCE`), and the slot is freed by the signature of the
    /// verdict, not by its finalization.
    function getJudgingCount(address arbiter) external view returns (uint256) {
        return ArbiterRegistryStorage.data().judgingCount[arbiter];
    }

    // -------- APPEAL PANEL: PAYMENT --------

    /// @notice A voter on an appeal pulls his share of the deposit.
    ///
    /// The panel's pay is written by `resolveAppeal` as one number per voter
    /// (`appealLedgers[agreement].voterShare`) rather than paid out there,
    /// because `resolveAppeal` is the one door that unfreezes an escrow and
    /// must not carry a cost that grows with turnout. So each voter comes for
    /// his own.
    ///
    /// ⚠️ NO SEAT, NO BOND, NO SUSPENSION CHECK — the same rule as
    /// `withdrawArbiterReward`: work already done is paid whatever the seat
    /// looks like today. A voter who resigned, was removed or was suspended
    /// after voting still takes what his vote earned.
    ///
    /// Effects before the transfer, and the transfer HARD: this is the voter's
    /// own pull, so a token that refuses him refuses nobody else, and the share
    /// stays where it was for the next attempt.
    ///
    /// `_msgSender()`, not `msg.sender`: an arbiter reaches this through the
    /// forwarder, and a raw sender there would be the forwarder, which voted on
    /// nothing.
    function withdrawAppealShare(address agreement) external {
        address caller = _msgSender();
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();

        uint256 amount = _appealShareOwed(d, agreement, caller);
        if (amount == 0) revert ArbiterRegistryFacet.NoAppealShare();
        d.appealShareTaken[agreement][caller] = true;

        bool ok = IUSDCFull(FactoryStorage.store().usdc).transfer(caller, amount);
        require(ok, "ArbiterRegistry: appeal share transfer failed");

        emit ArbiterRegistryFacet.AppealShareWithdrawn(agreement, caller, amount);
    }

    /// @notice What `voter` may pull right now for his vote on `agreement`'s
    /// appeal. Zero when there was no paid quorum, he did not vote, or he has
    /// already pulled.
    function getAppealShareOwed(address agreement, address voter) external view returns (uint256) {
        return _appealShareOwed(ArbiterRegistryStorage.data(), agreement, voter);
    }

    function _appealShareOwed(ArbiterRegistryStorage.Data storage d, address agreement, address voter)
        private view returns (uint256)
    {
        if (!d.hasVotedAppeal[agreement][voter] || d.appealShareTaken[agreement][voter]) return 0;
        return d.appealLedgers[agreement].voterShare;
    }

    /// @notice How a settled appeal's money was laid out: the panel's share per
    /// voter, and what the appellant's refund still owes back to the ruling
    /// arbiter's bond, to the bank, and what is still owed TO the appellant
    /// with nothing behind it. All zero for an appeal that was never settled.
    function getAppealLedger(address agreement)
        external
        view
        returns (uint256 voterShare, uint256 advanceFromBond, uint256 advanceFromVault, uint256 debt)
    {
        ArbiterRegistryStorage.AppealLedger storage l = ArbiterRegistryStorage.data().appealLedgers[agreement];
        return (l.voterShare, l.advanceFromBond, l.advanceFromVault, l.debt);
    }

    /// @notice What raising an appeal on `agreement` would cost right now. The
    /// same function `raiseAppeal` charges by, so the number a screen shows and
    /// the number a transfer takes cannot disagree.
    function quoteAppealDeposit(address agreement) external view returns (uint256) {
        return ArbiterRegistryStorage.appealDepositFor(agreement);
    }

    // -------- APPEAL DEBTS: THE BANK'S WAY OUT --------

    /// @notice Pays standing appeal debts out of the arbiter bank, oldest
    /// first, up to `maxCount` entries of the queue. Anyone may press it — the
    /// appellant owed the money first of all — and the money goes only to the
    /// appellants named in the ledgers, into `refundableBounty`, so the right
    /// to press decides nothing.
    ///
    /// ⚠️ WHY IT EXISTS (the owner's decision of 17 September 2026: money must
    /// have no dead ends). A won appeal on a small deal can leave the
    /// appellant owed more than the whole dispute fee — the deposit has a
    /// $20 floor, the fee on a $100 deal is $3 — and when the ruling arbiter's
    /// bond and the bank were both empty at that moment, nothing else was
    /// going to pay it. Two ways out now exist that do not depend on that fee:
    /// the arbiter's own top-up or resignation pays his debts first, and this
    /// door pays them out of whatever enters the bank afterwards.
    ///
    /// ⚠️ THE BANK IS THEIRS FIRST, NOT MERELY AVAILABLE TO THEM. Every other
    /// spend of the bank (a dispute top-up discount, a new appeal's advance)
    /// sees only `bankAboveDebts`, so money that arrives while debts stand
    /// cannot be spent past them before somebody presses this.
    ///
    /// Paying a debt out of the bank is booked as a bank advance on that deal
    /// (`advanceFromVault` grows), so if the deal's fee still arrives later its
    /// shares give the bank that money back.
    ///
    /// Bounded by `maxCount`, never by the length of the queue. Does not
    /// revert when there is nothing to pay.
    function settleAppealDebts(uint256 maxCount) external {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        address[] storage queue = d.appealDebtQueue;
        uint256 i   = d.appealDebtQueueHead;
        uint256 end = queue.length;
        uint256 bank = d.vaultBalance;
        uint256 paid;
        for (uint256 n = 0; i < end && n < maxCount && bank != 0; n++) {
            address agreement = queue[i];
            ArbiterRegistryStorage.AppealLedger storage l = d.appealLedgers[agreement];
            uint256 debt = l.debt;
            if (debt != 0) {
                uint256 pay = debt < bank ? debt : bank;
                bank -= pay;
                paid += pay;
                // uint64 cannot truncate: debt + advances never exceed one deposit.
                l.debt = uint64(debt - pay);
                l.advanceFromVault = uint64(l.advanceFromVault + pay);
                d.refundableBounty[l.appellant] += pay;
                emit ArbiterRegistryFacet.DisputeBountyRefundable(agreement, l.appellant, pay);
                // The bank ran dry inside this debt: it stays at the head.
                if (pay < debt) break;
            }
            i++;
        }
        d.appealDebtQueueHead = i;
        if (paid != 0) {
            d.vaultBalance = bank;
            d.appealDebtTotal -= paid;
        }
    }

    /// @notice The appeal debts standing right now: their sum, the first
    /// queue entry not yet known to be paid, and the queue's length.
    function getAppealDebts() external view returns (uint256 total, uint256 head, uint256 length) {
        ArbiterRegistryStorage.Data storage d = ArbiterRegistryStorage.data();
        return (d.appealDebtTotal, d.appealDebtQueueHead, d.appealDebtQueue.length);
    }

    function getChiefArbiter()  external view returns (address) { return ArbiterRegistryStorage.data().chiefArbiter; }
    function isRegisteredArbiter(address addr) external view returns (bool) { return ArbiterRegistryStorage.data().isArbiter[addr]; }

    function getArbiters()      external view returns (address[] memory) { return ArbiterRegistryStorage.data().arbiterList; }
    function getDisputeClaimer(address agreement) external view returns (address) { return ArbiterRegistryStorage.data().disputeClaims[agreement]; }

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
        if (abi.decode(statusData, (uint8)) != 4) revert ArbiterRegistryFacet.NotDisputed();

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
        // Only the bank above the appeal debts it owes (17 September 2026):
        // an appellant owed money comes before a discount.
        uint256 bank = ArbiterRegistryStorage.bankAboveDebts(ArbiterRegistryStorage.data());
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
}
