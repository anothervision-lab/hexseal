// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — FactoryFacet.sol
// Deploys Agreement contracts through the external AgreementDeployer.
// Takes the PPP fee in USDC, registers with RegistryFacet.
// ============================================================

import "./RegistryFacet.sol";
import "./AgreementDeployer.sol"; // the IAgreementDeployer interface only

// ---------- INTERFACES ----------

interface IRegistry {
    function register(address agreement, address client, address executor, uint256 amount) external;
    function hasActivePair(address client, address executor) external view returns (bool);
}


/// The fee floor is not configured — there is nothing to charge. A separate
/// error rather than ZeroFee: ZeroFee meant "the region is not configured", and
/// the price no longer has regions in it.
error FeeNotConfigured();

/// The fee no longer depends on the region. The getters are kept in the ABI but
/// revert: quietly returning a stale number is worse than failing.
error FeeNotRegional();

// ---------- STORAGE ----------

library FactoryStorage {
    /// @custom:storage-location erc7201:hexseal.factory.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.factory.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant FACTORY_STORAGE_POSITION = 0x6e1a7c9e564b098cf0d979de1ae0cacf8bfb22a7e8f2c8f4c244a2031b744700;

    uint8 constant REGION_CIS   = 0;
    uint8 constant REGION_ASIA  = 1;
    uint8 constant REGION_EU    = 2;
    uint8 constant REGION_US    = 3;
    uint8 constant REGION_LATAM = 4;
    uint8 constant REGION_CA    = 5;
    uint8 constant REGION_AU    = 6;

    struct Layout {
        address usdc;
        address feeRecipient;
        mapping(uint8 => uint256) regionFee;
        address trustedForwarder;
        address diamond;
        bool paused;
        address protocolArbiter;
        uint256 arbitrationThreshold;
        // Agreement deployer: holds the address of one deployed implementation
        // and clones it through EIP-1167. It no longer carries creation code
        // (945 bytes against the previous 23,849) — but it stays a separate
        // contract, so that the factory does not depend on the Agreement code
        // and can be pointed at a new implementation through
        // setAgreementDeployer without touching the facet.
        address agreementDeployer;
        // --- Fee model (28.07.2026) ---
        // Fee = max(amount * feeBps / 10_000, feeFloor). It is no longer
        // regional: regionFee above stays a dead field, because the storage
        // layout is append-only. One rate and one floor apply everywhere; the
        // regional getters stay mounted but revert with FeeNotRegional.
        uint256 feeBps;
        uint256 feeFloor;
        // Cap on simultaneously pending requests per CLIENT (across all
        // executors). 0 = no cap — that way an upgrade of a live diamond, where
        // the field is still zero, does not block requests.
        uint256 maxPendingRequests;
        // ---- appended 25 August 2026: fee earned, not yet delivered ----
        //
        // Protocol fee that is the protocol's money already, sitting on the
        // diamond because the push to `feeRecipient` did not go through. USDC
        // keeps a blacklist and `transfer` reverts on a blacklisted receiver,
        // so a fee push is a call that can fail forever through no fault of
        // the person making it — and it used to sit in the same transaction
        // that hands that person their refund.
        //
        // Zero is not "nothing was ever written here" in any harmful sense:
        // zero means nothing is owed, which is exactly the state of the live
        // diamond on the day this field appears.
        //
        // Whoever adds a new fee path adds it to this ledger too, or the
        // balance identity below stops holding:
        //   USDC.balanceOf(diamond) == jobFunds + jobFeeHeld + requestFunds
        //                            + requestFeeHeld + arbiter-namespace
        //                            balances + undeliveredFee
        uint256 undeliveredFee;
    }

    function store() internal pure returns (Layout storage fs) {
        bytes32 position = FACTORY_STORAGE_POSITION;
        assembly {
            fs.slot := position
        }
    }

    /// @notice The single implementation of the fee formula. FactoryFacet,
    ///         JobBoardFacet and ServiceBoardFacet all call it — there must be
    ///         no second copy.
    /// @dev The floor is applied AFTER the percentage: the larger of the two is
    ///      taken, not their sum.
    function quote(Layout storage fs, uint256 amount) internal view returns (uint256 fee) {
        uint256 floor_ = fs.feeFloor;
        if (floor_ == 0) revert FeeNotConfigured();
        fee = (amount * fs.feeBps) / 10_000;
        if (fee < floor_) fee = floor_;
    }

    /// @notice Hand `amount` of already-custodied fee to `feeRecipient`, and if
    ///         it will not take it, owe it instead. The single implementation
    ///         of that rule — JobBoardFacet and ServiceBoardFacet both call
    ///         this, and there must be no second copy, same as `quote`.
    ///
    /// @dev WHY THIS EXISTS. Every board path that returns money to a person
    ///      pushed the fee floor to `feeRecipient` in the same transaction. A
    ///      hard `require` on that push meant one dollar owed to a third party
    ///      decided whether tens of dollars belonging to the person came out at
    ///      all: on live job #3, 36.19 USDC behind a 1.00 USDC transfer. USDC
    ///      blacklists addresses, `Treasury` already made its OUTGOING payments
    ///      pull-based for exactly that reason, and the inflow never got the
    ///      same protection.
    ///
    ///      The happy path is untouched — the fee still lands in the same
    ///      transaction, and the caller still emits `FeeCollected`. Only a
    ///      refused transfer diverges, and it diverges into a debt, not into
    ///      silence: the amount is added to `undeliveredFee`, the caller emits
    ///      `FeeDeferred` instead, and `FactoryFacet.withdrawUndeliveredFees()`
    ///      pushes it later — the same shape as
    ///      `ArbiterRegistryFacet.refundableBounty` / `withdrawDisputeBounty`.
    ///
    ///      Swallowing the failure without booking it was the one outcome ruled
    ///      out from the start: the fee is protocol revenue, and "did not go
    ///      through, never mind" is a leak that no balance would ever show.
    ///
    /// @dev The return value is decoded defensively rather than through
    ///      `abi.decode(data, (bool))`, which reverts on a short or non-boolean
    ///      answer. A revert there would take the person's refund down with it
    ///      — the precise failure this function exists to prevent — so a reply
    ///      this code cannot read counts as "not delivered", which books the
    ///      debt rather than losing it.
    ///
    ///      No gas cap: the callee is the token itself, not a service beside
    ///      it. A token that burns gas takes the refund transfer with it too,
    ///      so a cap here would protect nothing (same reasoning as the other
    ///      USDC calls carried as reviewed exceptions to the diamond-call-gas
    ///      build gate).
    ///
    ///      A `usdc` address with no code would answer `ok == true` with empty
    ///      returndata and be read as delivered. That is the pre-existing
    ///      behaviour of every `_safeTransfer` in this repository and it is not
    ///      made worse here: with a codeless token no money entered the diamond
    ///      in the first place.
    ///
    /// @return delivered true if `feeRecipient` took the money.
    function settleFee(Layout storage fs, uint256 amount) internal returns (bool delivered) {
        if (amount == 0) return true;

        (bool ok, bytes memory data) = fs.usdc.call(
            abi.encodeWithSelector(0xa9059cbb, fs.feeRecipient, amount)
        );

        delivered = ok;
        if (delivered && data.length > 0) {
            if (data.length < 32) {
                delivered = false;
            } else {
                uint256 word;
                assembly ("memory-safe") { word := mload(add(data, 0x20)) }
                delivered = word != 0;
            }
        }

        if (!delivered) fs.undeliveredFee += amount;
    }
}

// ---------- FACET ----------

contract FactoryFacet {

    // -------- EVENTS --------

    event AgreementDeployed(
        address indexed agreement,
        address indexed client,
        address indexed executor,
        uint256 amount,
        uint8 region,
        uint256 fee
    );

    /// Fee that actually reached the treasury — the only complete source of
    /// protocol REVENUE. Not to be confused with
    /// `ArbiterRegistryFacet.withdrawTreasurySlice`: that function PAYS OUT what
    /// is already earned from the arbiter vault and also sends USDC to
    /// `feeRecipient`, but collects no new fee — it is an outflow of revenue
    /// already counted here, not a second source. AgreementDeployed.fee carries a
    /// recomputation as of the hire and may disagree with what was transferred.
    ///
    /// kind names both the board and the nature of the receipt — without it, id
    /// would stand for four different identifier spaces (jobId / serviceId /
    /// requestId / no identifier at all for a direct hire), and payment for a
    /// deal would be indistinguishable from the non-refundable floor on a cancel:
    ///   0 JOB_DEAL         — id = jobId,     fee on a job that happened
    ///   1 JOB_FORFEIT      — id = jobId,     floor left over on a cancelled job
    ///   2 SERVICE_LISTING  — id = serviceId, flat floor for posting a service
    ///   3 REQUEST_DEAL     — id = requestId, fee on a hire that happened
    ///   4 REQUEST_FORFEIT  — id = requestId, floor on reject/cancel/supersede
    ///   5 DIRECT_DEAL      — id = 0 (no natural id exists — the Agreement is
    ///                        not deployed yet at the moment of transfer), a
    ///                        direct hire through deployAndFund, bypassing both
    ///                        boards (deployAgreement no longer writes here —
    ///                        its entrance is closed to everyone but the diamond
    ///                        itself); the deal is recognised by the
    ///                        AgreementDeployed of the same transaction — the
    ///                        same way the subgraph already ties RequestAccepted
    ///                        to AgreementDeployed by transaction.
    event FeeCollected(uint256 indexed id, address indexed payer, uint8 indexed kind, uint256 amount);

    uint8 constant FEE_KIND_DIRECT_DEAL = 5;

    // -------- DEADLINE CEILING --------
    //
    // The longest deal the chain will create, in days. Same number both
    // boards have always enforced (JobBoardFacet, ServiceBoardFacet:
    // `deadlineDays == 0 || deadlineDays > 365`); direct hire enforced only
    // the zero half, so the ceiling did not exist on this path at all.
    //
    // It is not a taste question. `deadlineDays` lives in the clone as a raw
    // uint256 and is only ever used as `activatedAt + (deadlineDays * 1 days)`
    // -- six times, in status(), markDone, raiseDispute,
    // triggerDeadlineTimeout, proposeExtra and timeLeft. A number large enough
    // to overflow that product makes every one of those revert with Panic
    // 0x11, and the doors that do NOT touch it refuse for reasons of their own
    // (NotMarkedDone, AlreadyActive, NotDisputed). The result is escrowed USDC
    // with no way out and no rescuer -- Agreement has none by construction,
    // and a clone is nailed to its implementation for life (EIP-1167), so this
    // is not fixable after the fact for any deal already created.
    //
    // Measured, not reasoned about: test/DeadlineCap.t.sol builds that deal
    // and names what each of the seven doors returns.
    //
    // The ceiling stops far short of where the arithmetic breaks, on purpose:
    // 365 days is the product limit both boards already promise, and a value
    // that merely avoids overflow (say a million days, 2739 years) still takes
    // away the client's free "the executor vanished, give me my money back"
    // door forever, leaving only a paid dispute.
    uint256 constant MAX_DEADLINE_DAYS = 365;

    event RegionFeeUpdated(uint8 indexed region, uint256 newFee);
    event FeeRecipientUpdated(address indexed newRecipient);
    event TrustedForwarderUpdated(address indexed newForwarder);
    event DealFunded(address indexed agreement, address indexed client, uint256 amount);
    event AgreementDeployerUpdated(address indexed deployer);
    event FeeBpsUpdated(uint256 newBps);
    event FeeFloorUpdated(uint256 newFloor);
    event MaxPendingRequestsUpdated(uint256 newMax);

    /// A fee the boards booked as owed because `feeRecipient` would not take
    /// it, later handed over in one lump. Deliberately NOT `FeeCollected`: that
    /// event means "this much reached the treasury in this transaction", the
    /// subgraph turns it into protocol revenue, and re-emitting it here would
    /// count the same dollar twice — once when it was earned, once when it
    /// arrived. Same shape and same reason as
    /// `ArbiterRegistryFacet.TreasurySlicePushed`.
    event UndeliveredFeesPushed(address indexed recipient, uint256 amount);

    // -------- ERRORS --------

    error FactoryZeroAddress();
    error ZeroAmount();
    error ZeroDeadline();
    /// The deadline is above MAX_DEADLINE_DAYS. A name of its own rather than
    /// reusing ZeroDeadline: the two are opposite mistakes, and a client who
    /// typed a number in hours is helped by being told which end they are on.
    error DeadlineTooLong();
    error InvalidRegion();
    error ActiveDealExists();
    error ClientEqualsExecutor();
    error NotOwner();
    error AlreadyInitialized();
    error NotClient();
    /// `deployAgreement` is an entrance the diamond uses on itself, and this is
    /// what anybody else gets. Deliberately NOT `NotClient()`: the person most
    /// likely to knock IS the client, and telling a client "you are not the
    /// client" explains nothing. Same name and same meaning as
    /// `Agreement.NotDiamond()` (`Agreement.sol`, `setArbiter`), which guards
    /// the mirror-image door — and, being the same signature, it already
    /// decodes into a name in both relay tables.
    error NotDiamond();
    error DeployerNotSet();
    error FeeBpsTooHigh();
    /// Nothing is owed, so there is nothing to push. A distinct name rather
    /// than a silent no-op: a keeper that gets "done" for a zero transfer
    /// cannot tell a healthy ledger from a broken reader.
    error NothingUndelivered();

    // -------- OWNER CHECK --------

    function _owner() internal view returns (address) {
        return OwnershipLib.contractOwner();
    }

    modifier onlyOwner() {
        if (msg.sender != _owner()) revert NotOwner();
        _;
    }

    // -------- INIT --------

    function initFactory(
        address usdc_,
        address feeRecipient_,
        address trustedForwarder_,
        address diamond_,
        address agreementDeployer_
    ) external {
        FactoryStorage.Layout storage fs = FactoryStorage.store();
        if (fs.usdc != address(0)) revert AlreadyInitialized();
        if (msg.sender != _owner()) revert NotOwner();

        if (usdc_ == address(0)) revert FactoryZeroAddress();
        if (feeRecipient_ == address(0)) revert FactoryZeroAddress();
        if (trustedForwarder_ == address(0)) revert FactoryZeroAddress();
        if (diamond_ == address(0)) revert FactoryZeroAddress();
        if (agreementDeployer_ == address(0)) revert FactoryZeroAddress();

        fs.usdc              = usdc_;
        fs.feeRecipient      = feeRecipient_;
        fs.trustedForwarder  = trustedForwarder_;
        fs.diamond           = diamond_;
        fs.agreementDeployer = agreementDeployer_;

        fs.feeBps             = 500;        // 5%
        fs.feeFloor           = 1_000_000;  // $1
        fs.maxPendingRequests = 5;
    }

    /// @notice One-shot seeding of the fee model for an ALREADY initialized
    ///         diamond. It exists only for the upgrade of the live 0x760F…:
    ///         there initFactory ran long ago and reverts AlreadyInitialized,
    ///         while feeBps/feeFloor/maxPendingRequests are new fields that are
    ///         not in storage yet.
    /// @dev Called through the `_init`/`_calldata` of the same diamondCut that
    ///      mounts the facet: DiamondCutLib.initializeDiamondCut() performs
    ///      `_init.delegatecall(_calldata)` already inside the diamond's own
    ///      context, so `_init` is the address of the facet IMPLEMENTATION (not
    ///      of the diamond), storage resolves to the diamond's, and msg.sender
    ///      through the delegatecall is still the owner who called diamondCut —
    ///      onlyOwner here is a real gate, not decoration. Without this there is
    ///      a window between the cut and the configuring transaction in which
    ///      quote() reverts FeeNotConfigured, that is, ALL money paths revert,
    ///      including acceptApplicant/acceptRequest on jobs already posted.
    ///      The checks are the same as in setFeeBps/setFeeFloor: the one-shot
    ///      path must not be weaker than the ordinary one.
    function initFeeModel(uint256 bps, uint256 floor, uint256 maxPending) external onlyOwner {
        FactoryStorage.Layout storage fs = FactoryStorage.store();
        if (fs.feeFloor != 0) revert AlreadyInitialized();
        if (floor == 0) revert FeeNotConfigured();
        // Zero is stricter here than in setFeeBps: this path runs once and
        // cannot be undone, and a zero rate quietly returns the protocol to a
        // flat fee — quote() hands back the floor on any amount, with no revert
        // and no event. After that, a typo in one argument is fixable only by a
        // new diamondCut.
        if (bps == 0 || bps > 2_000) revert FeeBpsTooHigh();
        fs.feeBps = bps;
        fs.feeFloor = floor;
        fs.maxPendingRequests = maxPending;
        emit FeeBpsUpdated(bps);
        emit FeeFloorUpdated(floor);
        emit MaxPendingRequestsUpdated(maxPending);
    }

    // -------- DEPLOY AGREEMENT --------
    //
    // ⚠️ INTERNAL ENTRANCE. Only the diamond itself may call this — that is,
    // only JobBoardFacet.acceptApplicant and ServiceBoardFacet.acceptRequest,
    // both of which reach it as `address(this).call(...)` from inside the same
    // transaction. A person with a wallet cannot get here any more, and that is
    // the whole point of the function as it stands.
    //
    // WHY IT WAS CLOSED. This entrance creates a clone and does NOT fund it,
    // and there is no way back out of CREATED: the activation timeout answers
    // "not funded", the pair is now in the registry so the same two people
    // cannot be matched through a board again, and the only key left is to put
    // the FULL deal amount into a contract nobody will ever activate and wait
    // two days. The fee for that non-deal was taken up front.
    //
    // WHY CLOSING IT IS ENOUGH — measured, not reasoned about. Both boards
    // create and fund in ONE transaction: the `deployAgreement` call is
    // followed by `agreementAddr.call("fundFromFactory()")` under a `require`,
    // so a refused funding reverts the whole transaction and the clone never
    // exists. An unfunded clone could therefore only ever be born of a direct
    // call from outside. Take that away and the state with no exit stops being
    // reachable at all — which beats adding an escape hatch to a state nobody
    // can enter.
    //
    // The direct-hire road for people is `deployAndFund` below: it creates and
    // funds in one transaction, so it charges a fee for a deal that exists. It
    // stays open on purpose — `/deal/new` is that road's screen.
    function deployAgreement(
        address client,
        address executor,
        address, // arbiter — ignored, assigned at dispute claim time
        uint256 amount,
        uint256 deadlineDays,
        string calldata terms,
        uint8 region
    ) external returns (address agreementAddress) {
        if (client == address(0)) revert FactoryZeroAddress();
        if (executor == address(0)) revert FactoryZeroAddress();
        if (client == executor) revert ClientEqualsExecutor();
        if (amount == 0) revert ZeroAmount();
        if (deadlineDays == 0) revert ZeroDeadline();
        if (deadlineDays > MAX_DEADLINE_DAYS) revert DeadlineTooLong();
        if (region > 6) revert InvalidRegion();
        if (msg.sender != address(this)) revert NotDiamond();

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        if (fs.agreementDeployer == address(0)) revert DeployerNotSet();

        if (IRegistry(fs.diamond).hasActivePair(client, executor)) revert ActiveDealExists();

        // Priced, not charged: the caller is a board, and the board has been
        // holding this client's fee since the job was posted — it settles it
        // itself, a few lines after this call returns. The number is still
        // computed here because `AgreementDeployed` carries it, and a deal that
        // reported no fee would read as a free one to anything watching.
        //
        // The branch that used to take the fee here (`msg.sender == client`)
        // died with the direct-call road above. It could only fire again if the
        // diamond were somehow its own client, and then it would have pulled
        // USDC out of the escrow pool to pay a fee to itself.
        uint256 fee = FactoryStorage.quote(fs, amount);

        agreementAddress = IAgreementDeployer(fs.agreementDeployer).deploy(
            client, executor, address(0),
            amount, deadlineDays, terms,
            fs.diamond, fs.usdc, fs.trustedForwarder, address(this)
        );
        // Symmetric with deployAndFund: agreementDeployer is wired in through
        // the onlyOwner setAgreementDeployer and has already been swapped
        // several times (UpgradeAgreementDeployerV2/V3/V4) — a future deployer
        // without a zero check of its own must not slip silently into
        // register().
        if (agreementAddress == address(0)) revert FactoryZeroAddress();

        IRegistry(fs.diamond).register(agreementAddress, client, executor, amount);

        emit AgreementDeployed(agreementAddress, client, executor, amount, region, fee);
    }

    // -------- DEPLOY AND FUND --------

    function _msgSender() internal view returns (address sender) {
        address forwarder = FactoryStorage.store().trustedForwarder;
        if (msg.sender == forwarder && msg.data.length >= 20) {
            assembly { sender := shr(96, calldataload(sub(calldatasize(), 20))) }
        } else {
            sender = msg.sender;
        }
    }

    function deployAndFund(
        address client,
        address executor,
        uint256 amount,
        uint256 deadlineDays,
        string calldata terms,
        uint8 region
    ) external returns (address agreementAddress) {
        if (client == address(0)) revert FactoryZeroAddress();
        if (executor == address(0)) revert FactoryZeroAddress();
        if (client == executor) revert ClientEqualsExecutor();
        if (amount == 0) revert ZeroAmount();
        if (deadlineDays == 0) revert ZeroDeadline();
        if (deadlineDays > MAX_DEADLINE_DAYS) revert DeadlineTooLong();
        if (region > 6) revert InvalidRegion();
        if (_msgSender() != client) revert NotClient();

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        if (fs.agreementDeployer == address(0)) revert DeployerNotSet();

        if (IRegistry(fs.diamond).hasActivePair(client, executor)) revert ActiveDealExists();

        uint256 fee = FactoryStorage.quote(fs, amount);

        _safeTransferFrom(fs.usdc, client, fs.feeRecipient, fee);
        emit FeeCollected(0, client, FEE_KIND_DIRECT_DEAL, fee);

        agreementAddress = IAgreementDeployer(fs.agreementDeployer).deploy(
            client, executor, address(0),
            amount, deadlineDays, terms,
            fs.diamond, fs.usdc, fs.trustedForwarder, address(this)
        );
        if (agreementAddress == address(0)) revert FactoryZeroAddress();

        IRegistry(fs.diamond).register(agreementAddress, client, executor, amount);

        _safeTransferFrom(fs.usdc, client, agreementAddress, amount);

        (bool success, ) = agreementAddress.call(abi.encodeWithSignature("fundFromFactory()"));
        require(success, "Factory: fundFromFactory failed");

        emit AgreementDeployed(agreementAddress, client, executor, amount, region, fee);
        emit DealFunded(agreementAddress, client, amount);
    }

    // -------- SAFE TRANSFER --------

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Factory: fee transfer failed");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Factory: transfer failed");
    }

    // -------- ADMIN --------

    /// @dev DEPRECATED 28.07.2026 — symmetric with getRegionFee/getAllFees. The
    ///      selector stays mounted (a Remove is a separate diamondCut, and it is
    ///      not needed: the body is replaced by the same Replace as the rest of
    ///      the facet), but the write reverts. A working setter next to a
    ///      reverting getter would mean the admin panel "sets" fees that do
    ///      nothing — the rule "quietly accepting a stale number is worse than
    ///      failing" holds for writes as much as for reads.
    function setRegionFee(uint8, uint256) external pure {
        revert FeeNotRegional();
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert FactoryZeroAddress();
        FactoryStorage.store().feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setTrustedForwarder(address newForwarder) external onlyOwner {
        FactoryStorage.store().trustedForwarder = newForwarder;
        emit TrustedForwarderUpdated(newForwarder);
    }

    function setAgreementDeployer(address deployer) external onlyOwner {
        if (deployer == address(0)) revert FactoryZeroAddress();
        FactoryStorage.store().agreementDeployer = deployer;
        emit AgreementDeployerUpdated(deployer);
    }

    /// @notice The rate in basis points. 500 = 5%.
    function setFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > 2_000) revert FeeBpsTooHigh(); // 20% cap — guards against a typo in a zero
        FactoryStorage.store().feeBps = newBps;
        emit FeeBpsUpdated(newBps);
    }

    /// @notice The fee floor in USDC (6 decimals). Zero is forbidden — it would switch off the anti-spam.
    function setFeeFloor(uint256 newFloor) external onlyOwner {
        if (newFloor == 0) revert FeeNotConfigured();
        FactoryStorage.store().feeFloor = newFloor;
        emit FeeFloorUpdated(newFloor);
    }

    /// @notice Cap on pending requests per client. 0 = no cap.
    function setMaxPendingRequests(uint256 newMax) external onlyOwner {
        FactoryStorage.store().maxPendingRequests = newMax;
        emit MaxPendingRequestsUpdated(newMax);
    }

    // -------- READ --------

    /// @dev DEPRECATED 28.07.2026 — the fee is no longer regional. The selector is
    ///      kept in the ABI so that no Remove is needed in the diamondCut, but the
    ///      read reverts: regionFee in storage holds stale values.
    function getRegionFee(uint8) external pure returns (uint256) {
        revert FeeNotRegional();
    }

    /// @dev DEPRECATED 28.07.2026 — see getRegionFee.
    function getAllFees() external pure returns (
        uint256, uint256, uint256, uint256, uint256, uint256, uint256
    ) {
        revert FeeNotRegional();
    }

    /// @notice What a deal of this size will cost. The source of truth for the
    ///         frontend — computing the formula client-side is not allowed, it
    ///         would disagree with the permit.
    function quoteFee(uint256 amount) external view returns (uint256) {
        return FactoryStorage.quote(FactoryStorage.store(), amount);
    }

    function getFeeBps() external view returns (uint256) {
        return FactoryStorage.store().feeBps;
    }

    function getFeeFloor() external view returns (uint256) {
        return FactoryStorage.store().feeFloor;
    }

    function getMaxPendingRequests() external view returns (uint256) {
        return FactoryStorage.store().maxPendingRequests;
    }

    function getFeeRecipient() external view returns (address) {
        return FactoryStorage.store().feeRecipient;
    }

    // -------- UNDELIVERED FEE --------

    /// @notice Protocol fee earned by the boards, still on the diamond because
    ///         `feeRecipient` refused the transfer at the time.
    ///
    /// @dev This is the "you can see it" half of the promise. Without a reader,
    ///      a refused fee would exist only as one `FeeDeferred` log per
    ///      occurrence, and nobody would ever be able to answer "how much is
    ///      owed right now" without replaying every log the boards ever wrote.
    ///      It is also the term that keeps the diamond's USDC balance adding up
    ///      — see `FactoryStorage.Layout.undeliveredFee`.
    function getUndeliveredFees() external view returns (uint256) {
        return FactoryStorage.store().undeliveredFee;
    }

    /// @notice Push everything owed to the current `feeRecipient`.
    ///
    /// @dev Open on purpose, and for the same reason
    ///      `ArbiterRegistryFacet.withdrawTreasurySlice()` is: the money can
    ///      only go to the address in `FactoryStorage.feeRecipient`, so who
    ///      calls it decides nothing, while openness means the payout does not
    ///      depend on the owner remembering it and a keeper can push it.
    ///
    ///      Fails loudly rather than tolerantly, which is the opposite of
    ///      `settleFee` and deliberately so: this call has one job, and a
    ///      caller who is told "done" while the recipient still refuses has
    ///      been told nothing. The revert rolls back the zeroing with it, so
    ///      the debt survives a failed attempt intact.
    ///
    ///      No new power for the owner: `setFeeRecipient` already redirects
    ///      every dollar of fee income, so being able to redirect this one too
    ///      changes nothing about who is trusted with what. It is also the
    ///      recovery path — a permanently blacklisted treasury is replaced,
    ///      and the fees that piled up behind it follow the replacement.
    function withdrawUndeliveredFees() external {
        FactoryStorage.Layout storage fs = FactoryStorage.store();
        uint256 owed = fs.undeliveredFee;
        if (owed == 0) revert NothingUndelivered();

        fs.undeliveredFee = 0;

        address recipient = fs.feeRecipient;
        _safeTransfer(fs.usdc, recipient, owed);

        emit UndeliveredFeesPushed(recipient, owed);
    }

    function getTrustedForwarder() external view returns (address) {
        return FactoryStorage.store().trustedForwarder;
    }

    function getUsdc() external view returns (address) {
        return FactoryStorage.store().usdc;
    }

    function getAgreementDeployer() external view returns (address) {
        return FactoryStorage.store().agreementDeployer;
    }
}
