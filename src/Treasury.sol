// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — Treasury.sol
//
// Protocol treasury. Receives the fixed deal-creation fees and hands them
// down a ladder: arbiter vault buffer → foundation → reserve.
//
// It is installed by a single FactoryFacet.setFeeRecipient(treasury)
// transaction. Factory, escrow and boards do not change: they pay to an
// address, and whether a wallet or a contract sits there is indifferent
// to them.
//
// THERE IS NO ADMINISTRATOR. Not one owner-only function. The percentages
// are constant and nothing can change them; an error in the numbers is
// fixed only by a new contract and a new setFeeRecipient, which is visible
// from the outside.
//
// THE COST OF REPLACEMENT. setFeeRecipient redirects only FUTURE income.
// The accumulated reserveBalance stays in this contract. It leaves here by
// two paths: topUpVault() — permissionless, with no DAO gate, but only for
// exactly the vault shortfall and only after the income that has already
// arrived has been distributed (the sole reserve outflow before the DAO
// exists, see below); and withdrawReserve() — gated on the EARNED
// uniqueActiveUsers threshold rather than on isDaoActive() (see the
// withdrawReserve docstring — the gate there is deliberately stricter than
// the one on the share switch, and the HONEST limits of that strictness are
// stated there too). The accumulated foundationOwed also stays here, but is
// claimable at any moment through withdrawFoundation() — that is not
// disputed money, only what is due, and the DAO threshold has nothing to do
// with it.
// A migration function would require someone entitled to call it, that is,
// an administrator — which cancels everything written above. Accepted
// deliberately: the price of a mistake here is a frozen reserve, not a
// stolen one.
// The undistributed remainder (what is neither reserveBalance nor
// foundationOwed yet) is NOT frozen by a replacement. Distribution touches
// the diamond in THREE places, and all three are isolated so that the
// failure of any one of them does not bring the ladder down:
//   • the fundVault call itself — a raw CALL with a zero-length output
//     buffer; a failure is tolerated and does not revert the distribution
//     (see _fundVault);
//   • the getVaultBalance() read — a staticcall with a gas cap; a failure
//     reads as "nothing to top up" and the vault step is simply skipped
//     (vaultShortfall() → 0, see its docstring);
//   • the isDaoActive() read — a staticcall with a gas cap; a failure pins
//     the SMALLER of the two foundation shares, FOUNDATION_BPS_POST_DAO = 20%
//     (see foundationBps — the direction of degradation is chosen by
//     incentive).
// So everything above the current vaultShortfall still goes to the
// foundation and to the reserve on every subsequent distribute(). Only a
// tail no larger than vaultShortfall stays locked (that is, no larger than
// VAULT_TARGET, 500 USDC), and only while getVaultBalance() is ALIVE and
// reports a shortfall: if that read dies as well, the shortfall reads as
// zero and nothing is locked at all. The tail does not accumulate from call
// to call — the next distribute() attempts exactly the same amount and hits
// exactly the same limit. It is neither lost nor stolen — just pending
// indefinitely on the old contract.
//
// THE TRUST THE TREASURY IS OBLIGED TO EXTEND. The arbiter vault stands
// FIRST in the ladder deliberately — without it arbitration stops. But the
// draining of the vault is controlled by the diamond owner through
// setRewardPerDispute (onlyOwner in ArbiterRegistryFacet): while
// vaultShortfall is non-zero, all income goes there first. So the diamond
// owner, in concert with an arbiter of his own, can in theory keep the vault
// artificially dry (by inflating rewardPerDispute) and thereby pull treasury
// revenue through it instead of the honest foundation/reserve split. The
// treasury neither sees this nor can check it — it is obliged to trust
// someone, and this is a deliberate choice, not an oversight: the
// alternative (the treasury deciding for itself how much the vault "really"
// needs) would mean the treasury knows the business logic of arbitration
// better than the diamond itself does, which is false.
//
// The same bill is presented to the vault step WITHOUT any malice, and that
// is the second accepted residual risk. distribute() does not check that the
// vault ACCOUNTED for what was sent: _fundVault returns spent — how much
// USDC actually left the treasury — and that is all distribute() knows. A
// broken (not necessarily hostile: a failed facet upgrade is enough)
// fundVault that honestly accepts the transferFrom and forgets to record the
// increase in its own counter eats income SILENTLY. Measured: ten fee
// batches of 200 USDC, a distribute() after each — the diamond swallowed all
// 2000 USDC, foundationOwed 0, reserveBalance 0, the vault counter zero, and
// every call honestly emitted Distributed(200 USDC, 0, 0), that is, looked
// like successful work from the outside. topUpVault() DOES have the
// symmetric check (VaultDidNotGrow); here it is deliberately absent — a
// revert on such a postcondition would wall up the whole distribution, that
// is, would bring back through another door exactly the breakage steps 2 and
// 3 were detached from (see the comment in the body of distribute()). The
// loss ceiling is VAULT_TARGET (500 USDC) per distribute() call, so with
// small batches the whole income; the reserve and what is already credited
// to the foundation are not touched by distribute() at all.
//
// A PERMANENT CONSTRAINT ON THE DIAMOND. On top of the trust listed above
// comes one HARD requirement on the vault facet, and it has no expiry:
//
//     fundVault must not revert because of the SIZE of the amount passed,
//     for as long as this treasury is alive.
//
// No lower bound ("dust not accepted"), no upper bound, no rounding step, no
// other refusal that depends on amount. The reason is the DistributeFirst
// gate in topUpVault(): it tied the reserve outflow to the SUCCESS of the
// vault step inside distribute(). Today the requirement holds, and this is
// checked: ArbiterRegistryFacet.fundVault
// has no bound on the amount at all and refuses only on the caller.
//
// If a future facet upgrade breaks it, the price is this: 1 wei of USDC sent
// to the treasury by anyone walls up topUpVault() FOREVER. The mechanics are
// measured — dust makes pending non-zero; distribute() tries to hand it to
// the first step (toVault = min(shortfall, 1) = 1), fundVault rejects such an
// amount, spent stays zero, and pending does not change ON ANY CALL, however
// many are made. An atomic distribute()+topUpVault() bundle does not help,
// for the same reason. The reserve is neither stolen nor lost — it is simply
// cut off from the arbiter vault forever, that is, from its only purpose
// until the DAO exists.
//
// Recorded here rather than fixed in code, deliberately: there is nothing to
// fix — the treasury is immutable and cannot know which amounts a future
// facet will accept, and removing the gate would bring back the shifting of
// 210 USDC per round from the reserve to the foundation (see the topUpVault
// docstring). This is a constraint on the DIAMOND, and whoever upgrades it
// is the one obliged to honour it.
//
// With withdrawReserve() the same bill is presented to the reserve — and the
// trust is far sharper there, because the money leaves OUTWARDS. The
// getUniqueActiveUsers() >= DAO_THRESHOLD gate REALLY does hold against the
// MANUAL isDaoActive() flag (checked: activateDAO() + setDAOAddress without
// the earned threshold reverts DaoNotEarned, and the boundary sits exactly
// on DAO_THRESHOLD). But it is not protection against the diamond owner in
// general, and must not be presented as such: the treasury reads the counter
// out of an UPGRADEABLE contract and cannot be stricter than its owner.
// THREE live (not hypothetical) paths lead the same owner to the same
// result — the treasury sees none of them and cannot tell them apart from
// honest growth:
//
//   (a) diamondCut(Replace, [getUniqueActiveUsers() selector], evilFacet) —
//       one onlyOwner transaction swaps the counter for a function that
//       always returns DAO_THRESHOLD. Measured: 283 891 gas, which on Base
//       is less than five cents. DiamondCutFacet.diamondCut is gated only by
//       OwnershipLib.enforceIsContractOwner(), and
//       replaceFunctions allows ANY selector to be swapped for ANY facet
//       (DiamondCutLib.replaceFunctions) — there is neither a timelock nor a list
//       of untouchable selectors.
//
//   (b) Inflating the counter with HONEST deals. ReputationFacet credits
//       uniqueActiveUsers for every fresh address on a completed deal of
//       10 USDC or more (ReputationFacet._addXP), two unique addresses
//       per deal — 50 000 deals for the whole threshold. A full deal cycle
//       (creation → funding → activation → delivery → release) is measured
//       on a real diamond (test/TreasuryIntegration.t.sol) — 1 118 150 gas;
//       the result is 3-17 thousand dollars of gas against 192 thousand
//       dollars of reserve, and no capital is consumed: the escrow deposit
//       is recycled between deals.
//       An earlier revision claimed the owner also holds the
//       FactoryFacet.setRegionFee(region, 0) lever (onlyOwner, no lower
//       bound), zeroing out the "only real cost" of such inflation. That
//       UNDERSTATED the risk rather than overstating it: the protocol fee is
//       not a cost at all. It goes TO THE TREASURY, and the very next
//       distribute() turns it into foundationOwed (the foundation share) and
//       into reserve — that is, into exactly the money the attack is for. An
//       attacking owner recovers at least the reserve share of what was paid
//       (this same attack is what opens it for withdrawal), and if foundation
//       and key holder are one party (today they are), then all 100%. So no
//       fee lever is needed for the inflation at all, and the real price of
//       path (b) is GAS alone. setRegionFee is moot in any case: region fees
//       were dropped on 28 July 2026 and the setter now reverts
//       FeeNotRegional (FactoryFacet.setRegionFee).
//
//   (c) diamondCut(EMPTY cuts array, _init = any contract, _calldata) — one
//       onlyOwner transaction that mounts and removes NOTHING, but
//       delegatecalls arbitrary code and writes
//       ReputationStorage.data().uniqueActiveUsers = 100_000 straight into
//       the diamond's storage. The loop over cuts (DiamondCutLib.diamondCut)
//       simply does not run on an empty array, while initializeDiamondCut
//       (DiamondCutLib.initializeDiamondCut) executes anyway: _init has no timelock,
//       no allowlist and no check — only "has code". Measured on a real
//       diamond: 31 717 gas, nine times cheaper than (a). And unlike (a),
//       NOTHING IS VISIBLE in the loupe: facets() before and after are
//       byte-identical (compared by keccak), the set of facets and selectors
//       is unchanged, the counter is not swapped — the real ReputationFacet
//       honestly returns 100 000 out of the overwritten slot. Monitoring
//       facets and selectors cannot catch this path in principle; from the
//       outside only the DiamondCut event with a non-empty _init is visible.
//
// The difference from isDaoActive() alone is in the price and the visibility
// of the attack, not in any impossibility in principle: (a) costs pennies
// and is visible to anyone reading diamondCut events; (b) costs two orders
// of magnitude less than the reserve itself (and mostly comes back) and
// hides inside the ordinary flow of deals; (c) costs less than both and
// leaves no trace in any loupe view. The treasury can prevent none of the
// three — it reads the diamond's state, it does not control it. For a future
// reader: do not look for a hostile facet — on path (c) there is none.
// ============================================================

interface IUSDC {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IHexsealDiamond {
    function fundVault(uint256 amount) external;
    function getVaultBalance() external view returns (uint256);
    function isDaoActive() external view returns (bool);
    function getUniqueActiveUsers() external view returns (uint256);
    function getDAOAddress() external view returns (address);
}

contract Treasury {

    // -------- CONSTANTS (nothing can change them) --------

    /// Target of the arbiter vault buffer. Absolute by nature: a stock for
    /// N payouts, not a share of income. The vault neither overflows nor
    /// runs dry.
    uint256 public constant VAULT_TARGET = 500_000_000; // 500 USDC (6 decimals)

    uint256 public constant FOUNDATION_BPS_PRE_DAO  = 7_000; // 70%
    uint256 public constant FOUNDATION_BPS_POST_DAO = 2_000; // 20%
    uint256 public constant DAO_THRESHOLD           = 100_000; // uniqueActiveUsers

    uint256 private constant BPS = 10_000;

    /// Gas cap on a single read from the diamond (_readDiamondWord). Both
    /// reads the distribution depends on go through it: getVaultBalance()
    /// and isDaoActive().
    ///
    /// The cap is there not to save gas but because the work done on the
    /// callee's side is paid for by THIS transaction. A facet that inflates
    /// memory by 8 MB before returning costs about 135 million gas — without
    /// the cap distribute() would stop fitting into a block and would freeze
    /// forever while formally reverting nothing.
    ///
    /// 100 000 is chosen as follows. An honest read is the diamond fallback,
    /// a delegatecall into a facet and one or two SLOADs, on the order of
    /// 10 000 gas even cold. A tenfold margin leaves room for any reasonable
    /// future facet (one summing the vault out of several slots, say) and
    /// still bounds the worst case hard: two reads per distribute() add no
    /// more than 200 000 gas, which is negligible against the block limit.
    uint256 private constant DIAMOND_VIEW_GAS = 100_000;

    // -------- IMMUTABLE --------

    address public immutable usdc;
    address public immutable diamond;
    /// A single address. What stands behind it — team, investor,
    /// infrastructure — the treasury does not know and must not know: that
    /// is a paper agreement, not code.
    address public immutable foundation;

    // -------- STORAGE --------

    /// How much of the USDC held here is already assigned to the reserve.
    uint256 public reserveBalance;

    /// How much is owed to the foundation and not yet taken through
    /// withdrawFoundation().
    ///
    /// The foundation payout is pull-based rather than made "at the moment of
    /// distribution": USDC has a Circle blacklist, and the foundation address
    /// landing on it would make transfer revert right inside distribute() —
    /// and with it the whole distribution, forever, because foundation is
    /// immutable and there is nothing to route around it. The debt simply
    /// accrues while the vault and the reserve keep filling as usual; this is
    /// the same class of breakage already isolated at the vault step through
    /// _fundVault — no step of the ladder may wall up the rest.
    uint256 public foundationOwed;

    /// Together reserveBalance and foundationOwed are the whole state of the
    /// money ACCOUNTING. Not the whole state of the contract: a third storage
    /// variable exists — _status of the reentrancy guard (declared below) —
    /// but it counts no money and between transactions always equals
    /// NOT_ENTERED. Everything else is derived from the actual balance:
    /// pendingDistribution() = balanceOf(treasury) − reserveBalance −
    /// foundationOwed. USDC sent here directly by anyone simply grows the
    /// undistributed part and lands in the next distribute() — neither one
    /// breaks the accounting.

    // -------- REENTRANCY --------
    //
    // The simplest guard, in the style of the ReentrancyGuard in
    // Agreement.sol, with no external dependencies. In Agreement the ordinary
    // constructor is displaced by a clone plus initialize(), so _status there
    // is initialised by a separate method; Treasury has exactly one
    // constructor, called exactly once — initialisation happens right inside
    // it, and a separate method here would be surplus surface.

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status;

    modifier nonReentrant() {
        if (_status == ENTERED) revert Reentrancy();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    // -------- EVENTS --------

    event Distributed(uint256 toVault, uint256 toFoundation, uint256 toReserve);
    event VaultToppedUp(uint256 amount);
    event ReserveWithdrawn(address indexed dao, uint256 amount);
    event FoundationWithdrawn(uint256 amount);

    // -------- ERRORS --------

    error ZeroAddress();
    error NoCode();
    error NothingToDistribute();
    error DistributeFirst();
    error TransferFailed();
    error ApproveFailed();
    error Reentrancy();
    error NothingOwed();
    error VaultAtTarget();
    error ReserveEmpty();
    error VaultFundingFailed();
    error VaultDidNotGrow();
    error DaoNotEarned();
    error DaoAddressUnset();
    error NotDao();
    error InvalidAmount();

    constructor(address usdc_, address diamond_, address foundation_) {
        if (usdc_ == address(0) || diamond_ == address(0) || foundation_ == address(0)) revert ZeroAddress();
        // Both external contracts must have code: in the EVM a call to an
        // address without code returns SUCCESS. For the diamond that would
        // mean approve went through, fundVault "succeeded", and the money
        // stayed on the treasury while counted as sent to the vault. For USDC
        // it would mean balanceOf/transfer silently return emptiness instead
        // of failing, and the whole bookkeeping of the contract loses its
        // footing.
        if (usdc_.code.length == 0) revert NoCode();
        if (diamond_.code.length == 0) revert NoCode();
        usdc       = usdc_;
        diamond    = diamond_;
        foundation = foundation_;
        _status    = NOT_ENTERED;
    }

    // -------- THE LADDER --------

    /// @notice Distribute everything accumulated since last time.
    ///
    /// Anyone may call it. That is not an omission: ERC-20 has no callback,
    /// so the treasury cannot learn of an incoming fee at the moment it
    /// arrives.
    ///
    /// HONESTLY about what the right to call confers. An earlier revision
    /// said here that "neither the moment nor the caller affects the split" —
    /// untrue in both directions. The MOMENT does affect it: the share of the
    /// first step equals vaultShortfall() in the calling block, and that
    /// moves independently of the treasury (arbiter payouts, the onlyOwner
    /// setRewardPerDispute). What the caller can NOT change is WHO pays for
    /// the vault. Before the DistributeFirst gate he could: calling
    /// topUpVault() ahead of distribute() shifted the vault step off income
    /// onto the reserve, and on a single shortfall that was measured to move
    /// up to 210 USDC from the reserve to the foundation (see the topUpVault
    /// docstring). Now the order of steps is rigid: income is distributed
    /// first, and only afterwards does the reserve top the vault up. The
    /// recipients, the rule of computation and the order of the steps do not
    /// depend on the caller at all — the right to call confers no advantage.
    function distribute() external nonReentrant {
        uint256 pending = pendingDistribution();
        if (pending == 0) revert NothingToDistribute();

        // This guard protects the MONEY, not merely the telemetry: without it
        // the treasury becomes insolvent. Measured (an attacker reenters
        // distribute() from fundVault() BEFORE its own pull, and at the
        // deepest level reports a full vault): the nested call, seeing a
        // collapsed vaultShortfall() == 0, marks ONE HUNDRED PERCENT of its
        // pending into reserveBalance/foundationOwed — including money that
        // the level above has ALREADY approved for withdrawal and that the
        // diamond pulls immediately after the return from that nested call.
        // Measured at depths 2-4 (same result): pending 1 000 000 000,
        // actually pulled by the vault 500 000 000, marked 1 000 000 000 —
        // the treasury is insolvent by up to VAULT_TARGET (500 000 000).
        //
        // Separately (and this still holds): nesting cannot draw out more
        // money than the original OUTER pending — measured at depth 6, in
        // different orders and with 5000 USDC already marked: the extraction
        // maximum is always VAULT_TARGET, because the approve() of each level
        // is bounded by min(vaultShortfall(), pending) <= VAULT_TARGET and is
        // reset to 0 as the stack unwinds. That is a bound on theft above the
        // limit, not on solvency — solvency is held by nonReentrant alone.
        //
        // If instead the reentrant does its pull BEFORE attempting reentrancy
        // (so vaultShortfall() does not collapse), the money is in no danger —
        // but four Distributed events with a combined toVault of
        // 2 000 000 000 were measured instead of one with zero: the guard
        // additionally prevents the body of distribute() from executing twice
        // within one external call.
        uint256 toVault = vaultShortfall();
        if (toVault > pending) toVault = pending;
        uint256 rest = pending - toVault;
        uint256 toFoundation = (rest * foundationBps()) / BPS;

        // The reserve is the whole remainder. Computed by subtraction rather
        // than as a second share: that way no cent can be lost to rounding.
        uint256 toReserve = rest - toFoundation;

        if (toReserve > 0)    reserveBalance += toReserve;
        if (toFoundation > 0) foundationOwed += toFoundation;

        // Step 1. The arbiter vault buffer — up to target and not a cent
        // more. A failure of this step (the treasury was replaced and the
        // diamond no longer lets it into fundVault, a giant revert payload
        // and so on) must not bring down steps 2 and 3 — see _fundVault.
        uint256 spent = 0;
        if (toVault > 0) (, spent) = _fundVault(toVault);

        // There is NO "the vault REALLY accounted for the increase"
        // postcondition here, and that is not an oversight but the other side
        // of the same decoupling. topUpVault() has such a check
        // (VaultDidNotGrow) and must have it: there the reserve is already
        // debited, and a revert is the only way to undo the debit. Here a
        // revert would mean a broken vault WALLS UP the whole distribution —
        // exactly the breakage steps 2 and 3 were detached from above, only
        // through another door. So spent takes part in the event alone. The
        // price of that decision is measured and written in the file header
        // ("THE TRUST THE TREASURY IS OBLIGED TO EXTEND"): a silent loss of up
        // to VAULT_TARGET per call, and with small batches the whole income.
        // It is not hidden.
        emit Distributed(spent, toFoundation, toReserve);
    }

    // -------- TOPPING UP THE VAULT --------

    /// @notice Top the arbiter vault up out of the reserve.
    ///
    /// The sole reserve outflow before the DAO exists. Anyone may call it,
    /// but the transfer happens ONLY when the vault is below target, ONLY for
    /// the missing amount (min(shortfall, reserve) in the calling block) and
    /// ONLY once all the income that arrived has been distributed by
    /// distribute().
    ///
    /// HONESTLY about what the right to call confers. An earlier revision
    /// said here that the choice of moment gives the caller "NOTHING". That
    /// was untrue, and the price of the untruth is measured. The caller
    /// chooses the MOMENT and thereby indirectly affects the amount (a call
    /// right after a large arbiter payout moves more than a call before it) —
    /// that part remains. But he also affected WHO pays for the vault, and
    /// that already moved money between recipients. Measured from an
    /// identical start (reserve 300 USDC, vault short by 500, 1000 USDC
    /// arrived): distribute() first — reserve 450, foundation 1050;
    /// topUpVault() first — reserve 240, foundation 1260. 210 USDC moved
    /// merely from swapping two open calls, by the formula
    /// Δ = foundationBps × S, where S is how much of the vault the reserve
    /// paid for. Repeatable on every shortfall, and the incentive to choose
    /// the second order belongs to the foundation itself — so in practice the
    /// vault would ALWAYS be financed out of the reserve and the first step of
    /// the ladder would become decorative. The DistributeFirst gate below
    /// closes this.
    ///
    /// The state this rule computes from (vaultShortfall, that is, the
    /// diamond's current getVaultBalance()) is itself moved by the diamond
    /// owner through the onlyOwner setRewardPerDispute in
    /// ArbiterRegistryFacet — see "THE TRUST THE TREASURY IS OBLIGED TO
    /// EXTEND" in the file header. There that trust is described only for
    /// FUTURE income; topUpVault extends the same lever to the reserve ALREADY
    /// accumulated: an owner draining the vault between calls (or simply
    /// keeping it artificially dry) can carry off the entire reserve in as
    /// many calls as VAULT_TARGET fits into the reserve (each call moves no
    /// more than VAULT_TARGET) — the same deliberate trade-off as in
    /// distribute(), only at a higher stake (the whole accumulated reserve,
    /// not just future income).
    ///
    /// Covers both a surge of disputes and the subsidy of the lower bound on
    /// small disputes: both show up identically, as a vault shortfall.
    function topUpVault() external nonReentrant {
        // The reserve pays for the vault only after the income has been
        // distributed. Without this condition the order in which two open
        // functions are called would decide who finances the vault: calling
        // topUpVault() before distribute() was measured to shift up to
        // 210 USDC per round from the reserve to the foundation, and the
        // incentive to choose that order belongs to the foundation itself. The
        // design puts income as the first step of the ladder — this condition
        // makes that so in fact, not merely in words.
        //
        // The check stands FIRST, before the shortfall is computed, so that
        // the order of refusals is predictable: "distribute the income first"
        // is heard before "the vault is full anyway".
        //
        // It creates no deadlock — but the condition is more precise than
        // "distribute() ALWAYS zeroes the undistributed part". The algebra is
        // simple: after distribute() what remains is pending = toVault −
        // spent, that is, zero exactly when the vault step spent EVERYTHING it
        // was given (the special case being a full vault, with toVault zero).
        // While fundVault accepts money this always holds, and topUpVault() is
        // reachable immediately after distribute().
        //
        // When the vault does NOT accept money, no deadlock is needed either:
        // sinking the reserve into a broken vault is impossible under any
        // order of calls. But no particular error can be promised in that
        // case, and an earlier revision of this comment promised the wrong
        // one. Measured in the header's own scenario (the treasury was
        // replaced through setFeeRecipient, fundVault reverts): the
        // undistributed part sticks at exactly vaultShortfall (500 000 000)
        // and grows no further, and topUpVault() refuses on THIS check,
        // DistributeFirst — control never reaches VaultFundingFailed. The
        // money is intact, the reserve is not debited; only the error text
        // differs.
        //
        // The flip side, honestly: an outsider can postpone topUpVault() by
        // one block by sending the treasury USDC dust — dust makes pending
        // non-zero. Cured by that same distribute(), open to anyone; no money
        // moves in the meantime. Why "by a block" and not "forever", and what
        // must stay true in the diamond for that to hold, is in "A PERMANENT
        // CONSTRAINT ON THE DIAMOND" in the file header.
        if (pendingDistribution() != 0) revert DistributeFirst();

        uint256 shortfall = vaultShortfall();
        if (shortfall == 0) revert VaultAtTarget();

        uint256 amount = shortfall > reserveBalance ? reserveBalance : shortfall;
        if (amount == 0) revert ReserveEmpty();

        // Here and in the postcondition below getVaultBalance() is read by an
        // ORDINARY typed call rather than through _readDiamondWord, on
        // purpose. Degradation is needed where a failed read walls up the
        // distribution forever (distribute); topUpVault is all-or-nothing
        // anyway, its revert locks nothing, and quietly carrying on here after
        // an unread balance would be worse than a revert: the reserve is
        // already debited. Control does not even reach this line if the read
        // is dead — vaultShortfall() above returns 0 and the call fails on
        // VaultAtTarget.
        uint256 vaultBefore = IHexsealDiamond(diamond).getVaultBalance();

        // The reserve shrinks BEFORE the external call, and the quantity
        // vaultShortfall() reads below is only partially marked (unlike
        // distribute(), which marks the WHOLE pending before calling the
        // vault). Without nonReentrant a reentrant would see the reduced
        // reserveBalance while vaultShortfall() is unchanged (the vault
        // itself is not topped up yet) and would debit the reserve a second
        // time for the very same shortfall.
        reserveBalance -= amount;
        (bool ok, uint256 spent) = _fundVault(amount);
        // All or nothing — and this is DELIBERATELY the opposite of what
        // distribute() does. There a failure of the first step is tolerated,
        // otherwise replacing the treasury through setFeeRecipient would wall
        // up the entire undistributed remainder. Here it must not be
        // tolerated: the reserve is already debited, and a silent failure
        // would mean money left the reserve without reaching the vault. The
        // revert returns the debit along with the whole transaction.
        if (!ok || spent != amount) revert VaultFundingFailed();

        // spent == amount proves only that the USDC LEFT the treasury — not
        // that the vault ACCOUNTED for it. Those are two different facts: a
        // broken (not necessarily hostile — during a future facet upgrade, for
        // instance) fundVault may honestly accept the transferFrom and forget
        // to record the increase in its own counter. So it is checked
        // separately that getVaultBalance() grew by at least amount — "at
        // least", not "exactly", because another (including a future)
        // fundVault is entitled to credit MORE than it actually pulled (adding
        // something of its own on top of what was requested, say) — exact
        // equality would forbid such a facet without good reason.
        uint256 vaultAfter = IHexsealDiamond(diamond).getVaultBalance();
        if (vaultAfter < vaultBefore + amount) revert VaultDidNotGrow();

        emit VaultToppedUp(amount);
    }

    // -------- RESERVE EXIT TO THE DAO --------

    /// @notice Withdraw the reserve to the DAO address. DAO only, and only on
    /// the EARNED threshold.
    ///
    /// The gate here is deliberately stricter than the one on the share
    /// switch, and here is why. isDaoActive() is true on EITHER of two
    /// conditions: the owner's manual flag (daoActiveManual) OR the earned
    /// threshold of unique users. The diamond owner can point daoAddress at
    /// his own wallet and raise the manual flag — so under isDaoActive() the
    /// reserve would be withdrawable at his discretion. Hence only
    /// uniqueActiveUsers is asked here.
    ///
    /// The asymmetry is not accidental: switching the shares early REDUCES the
    /// foundation's share, so abusing it costs the abuser more than it gains
    /// and a soft gate suffices. Withdrawing the reserve benefits whoever does
    /// it, so the gate here is stricter: the MANUAL flag (activateDAO()) on
    /// its own no longer opens the withdrawal — a checked and real property
    /// (the boundary is verified exactly on DAO_THRESHOLD).
    ///
    /// But this is NOT protection against the diamond owner in general, and
    /// there is no need to present it as such: getUniqueActiveUsers() is read
    /// out of an UPGRADEABLE diamond, so the treasury cannot be stricter than
    /// its owner. THREE live (not hypothetical) paths lead the same owner to
    /// the same result: a diamondCut on the counter itself; inflating the
    /// counter with HONEST deals, where the protocol fee is not a cost at all
    /// because it comes back to the owner through this very treasury (so no
    /// fee lever is needed for it — only gas is paid); and a diamondCut with
    /// an EMPTY cuts array but with an _init that writes the counter straight
    /// into storage, touching not one selector and changing not one byte in
    /// the loupe. All three are analysed and measured in the file header,
    /// section "THE TRUST THE TREASURY IS OBLIGED TO EXTEND". The difference
    /// from isDaoActive() is in the cost and the visibility of the attack, not
    /// in any impossibility in principle.
    function withdrawReserve(uint256 amount) external nonReentrant {
        // The threshold check comes before the address check on purpose: even
        // if the address is not set yet, the answer must be "the DAO is not
        // earned" rather than "there is no address" — otherwise it could look
        // from outside as though setDAOAddress alone would have opened the
        // withdrawal, with no real threshold.
        if (IHexsealDiamond(diamond).getUniqueActiveUsers() < DAO_THRESHOLD) revert DaoNotEarned();

        // The DAO address is address(0) by default (see ArbiterRegistryStorage)
        // until the diamond owner calls setDAOAddress. Real USDC reverts on a
        // transfer to zero — without an explicit check here the refusal would
        // look like a bare token revert with no error of its own.
        address dao = IHexsealDiamond(diamond).getDAOAddress();
        if (dao == address(0)) revert DaoAddressUnset();
        if (msg.sender != dao) revert NotDao();
        if (amount == 0) revert InvalidAmount();

        // Take the lesser of requested and available rather than reverting on
        // a shortfall. The reason is not convenience: two parties spend the
        // reserve, and one of them — topUpVault() — is open to anyone. On a
        // revert any outsider could break the DAO's withdrawal by calling
        // topUpVault() first: that would lawfully reduce the reserve, and the
        // DAO's transaction would fail on the subtraction. Clamping makes the
        // withdrawal robust against such front-running. It also keeps
        // undistributed money out of reach: toSend is bounded by
        // reserveBalance, not by the actual balanceOf(treasury).
        uint256 toSend = amount > reserveBalance ? reserveBalance : amount;
        if (toSend == 0) revert ReserveEmpty();

        reserveBalance -= toSend;
        if (!IUSDC(usdc).transfer(dao, toSend)) revert TransferFailed();

        // The event carries what was actually sent, not what was requested.
        emit ReserveWithdrawn(dao, toSend);
    }

    // -------- FOUNDATION WITHDRAWAL --------

    /// @notice Claim what has been credited to the foundation.
    ///
    /// Anyone may call it — the money leaves only for the immutable
    /// foundation address anyway, so the right to call decides nothing, while
    /// openness means an outsider can "push" the payout through if the
    /// foundation itself cannot be bothered.
    function withdrawFoundation() external nonReentrant {
        uint256 amount = foundationOwed;
        if (amount == 0) revert NothingOwed();
        foundationOwed = 0;
        if (!IUSDC(usdc).transfer(foundation, amount)) revert TransferFailed();
        emit FoundationWithdrawn(amount);
    }

    // -------- VIEWS --------

    /// How much sits on the treasury above what is already marked (the reserve
    /// plus what is owed to the foundation).
    function pendingDistribution() public view returns (uint256) {
        uint256 balance = IUSDC(usdc).balanceOf(address(this));
        uint256 earmarked = reserveBalance + foundationOwed;
        return balance > earmarked ? balance - earmarked : 0;
    }

    /// How much the arbiter vault is short of its target.
    ///
    /// A failed read is NOT a revert but 0: "nothing to top up". The vault
    /// step is simply skipped and the ladder keeps working — the income goes
    /// wholly to the foundation and the reserve. An ordinary typed call
    /// through the fallback is inadmissible here: a removed or broken
    /// getVaultBalance() selector would bring down both distribute() and
    /// topUpVault(), that is, would freeze 100% of the undistributed part AND
    /// of all future income — instead of a tail the size of VAULT_TARGET,
    /// which is what the file header promises. This is not hypothetical:
    /// ArbiterRegistryFacet has been upgraded about seven times in three
    /// months, and fourteen scripts under script/ perform
    /// FacetCutAction.Remove.
    function vaultShortfall() public view returns (uint256) {
        (bool ok, uint256 balance) = _readDiamondWord(IHexsealDiamond.getVaultBalance.selector);
        if (!ok) return 0;
        return balance >= VAULT_TARGET ? 0 : VAULT_TARGET - balance;
    }

    /// The foundation's share in the current mode.
    ///
    /// The gate is soft (isDaoActive() counts the owner's manual flag too) on
    /// purpose: switching early REDUCES the foundation's share, so abusing it
    /// costs the abuser more than it gains. withdrawReserve() has the opposite
    /// incentive (there an early manual DAO activation would, on the contrary,
    /// OPEN the withdrawal at the owner's discretion) — so its gate is
    /// deliberately different: not isDaoActive() but getUniqueActiveUsers() >=
    /// DAO_THRESHOLD directly, which no single manual flag can switch. This is
    /// NOT protection against the diamond owner in general — see the
    /// withdrawReserve docstring and the file header ("THE TRUST THE TREASURY
    /// IS OBLIGED TO EXTEND") on the three live paths by which the same owner
    /// gets around this gate as well.
    ///
    /// A failed read is NOT a revert but FOUNDATION_BPS_POST_DAO (20%), the
    /// SMALLER of the two shares. The direction of degradation is chosen by
    /// incentive rather than by "safe by default": degrading to 70% would hand
    /// the diamond owner the lever "break isDaoActive() with one diamondCut
    /// and pin the larger share for yourself forever". At 20% breaking the
    /// read costs him more than it gains. This is the same asymmetry of
    /// incentives the withdrawReserve() gate already rests on (see its
    /// docstring): where abuse does not pay the abuser, a separate defence
    /// need not be built.
    function foundationBps() public view returns (uint256) {
        (bool ok, uint256 daoActive) = _readDiamondWord(IHexsealDiamond.isDaoActive.selector);
        if (!ok) return FOUNDATION_BPS_POST_DAO;
        return daoActive != 0
            ? FOUNDATION_BPS_POST_DAO
            : FOUNDATION_BPS_PRE_DAO;
    }

    // -------- INTERNAL --------

    /// Reads ONE 32-byte word from the diamond, leaving the callee no way to
    /// revert this transaction, burn its gas, or flood its memory.
    ///
    /// The same threat model as in _fundVault, extended to READS: the diamond
    /// owner may mount a hostile or merely broken facet, or remove the
    /// selector outright. A typed call through the fallback then reverts and
    /// drags the whole distribution with it — see the vaultShortfall() and
    /// foundationBps() docstrings, which spell out what exactly that costs
    /// each of the two reads.
    ///
    /// Three limits at once:
    ///   • staticcall — the callee can neither change state nor reenter
    ///     anything that writes;
    ///   • an output buffer of exactly 0x20 — the EVM will not copy more than
    ///     32 bytes into this memory, whatever the callee answers (the same
    ///     trick as the zero-length buffer in _fundVault);
    ///   • gas bounded by DIAMOND_VIEW_GAS — see the constant.
    ///
    /// An answer shorter than a word counts as a failure: success with empty
    /// returndata (a call to an address whose code has vanished, say) would
    /// otherwise pass the contents of uninitialised memory off as the value
    /// read.
    function _readDiamondWord(bytes4 selector) private view returns (bool ok, uint256 word) {
        address to = diamond;
        uint256 gasCap = DIAMOND_VIEW_GAS;
        assembly ("memory-safe") {
            // Scratch space past the free memory pointer: the pointer itself
            // is not moved and nothing long-lived stays here. In Yul a
            // selector sits left-aligned in a word, so mstore plus a length
            // of 4 give exactly four bytes of calldata. The output buffer is
            // the same address: the input is read before the EVM starts
            // writing the answer.
            let ptr := mload(0x40)
            mstore(ptr, selector)
            ok := staticcall(gasCap, to, ptr, 4, ptr, 0x20)
            if lt(returndatasize(), 0x20) { ok := 0 }
            word := mload(ptr)
        }
        if (!ok) word = 0;
    }

    /// Attempts to fund the vault with amount. Returns (ok, spent): ok —
    /// whether the diamond call itself succeeded, spent — how much actually
    /// left the treasury's balance (may be less than amount if fundVault
    /// decides not to take it all, and always 0 when !ok). The approval is
    /// zeroed in both cases: on success fundVault may have taken less than
    /// everything, and on failure (the treasury was replaced through
    /// setFeeRecipient, say, and the diamond no longer lets it into
    /// fundVault) it would hang there indefinitely.
    ///
    /// What to do about !ok is decided by the caller, not by this function —
    /// and the callers decide differently. There are two of them today:
    /// distribute() deliberately ignores ok and works only with spent — a
    /// vault failure must not bring down the foundation and the reserve.
    /// topUpVault(), by contrast, cannot tolerate !ok and honestly reverts: it
    /// is an explicit one-off call, not a background distribution, and by that
    /// point the reserve is already debited.
    ///
    /// The diamond call is made as a raw CALL with a zero-length output
    /// buffer — the same trick as in MinimalForwarder.execute(): `.call(...)`
    /// at the Solidity level always copies ALL of returndata into memory
    /// before the code gets a chance to discard it, regardless of what the
    /// code then does with the result (checked: a diamond with a facet whose
    /// fundVault reverts with a megabyte payload otherwise freezes
    /// distribute() on gas — and the diamond owner can mount such a facet
    /// through diamondCut at any moment). Here the returned data is not needed
    /// at all, only the success flag — with a zero-length output buffer the
    /// EVM copies nothing.
    function _fundVault(uint256 amount) private returns (bool ok, uint256 spent) {
        uint256 balanceBefore = IUSDC(usdc).balanceOf(address(this));
        if (!IUSDC(usdc).approve(diamond, amount)) revert ApproveFailed();

        address to = diamond;
        bytes memory payload = abi.encodeWithSelector(IHexsealDiamond.fundVault.selector, amount);
        assembly ("memory-safe") {
            ok := call(gas(), to, 0, add(payload, 0x20), mload(payload), 0, 0)
        }

        // The approval is zeroed regardless of the outcome of the call above.
        if (!IUSDC(usdc).approve(diamond, 0)) revert ApproveFailed();

        uint256 balanceAfter = IUSDC(usdc).balanceOf(address(this));
        // If the balance did not decrease (including an unexpected increase),
        // treat it as nothing spent — subtracting the other way round would
        // give Panic 0x11 and bring down the whole distribution.
        spent = balanceAfter < balanceBefore ? balanceBefore - balanceAfter : 0;
    }
}
