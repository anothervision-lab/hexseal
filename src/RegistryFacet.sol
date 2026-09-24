// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — RegistryFacet.sol
// Holds every deal, its status, and the client+executor pairs
// Lives inside the Diamond — one address forever
// ============================================================

import "./DiamondProxy.sol";

// ---------- STORAGE ----------

library RegistryStorage {
    /// @custom:storage-location erc7201:hexseal.registry.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.registry.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant REGISTRY_STORAGE_POSITION = 0xc2046377b613f781ce75bf5776eb70f650372f5239ada8a3238d951cdca15e00;

    enum AgreementStatus {
        ACTIVE,
        COMPLETED,
        REFUNDED,
        DISPUTED,
        RESOLVED
    }

    struct AgreementRecord {
        address agreement;   // address of the Agreement contract
        address client;      // the party ordering the work
        address executor;    // the party doing the work
        uint256 amount;      // deal amount in USDC (6 decimals)
        AgreementStatus status;
        uint256 createdAt;
        uint256 resolvedAt;
    }

    struct Layout {
        // agreement address → record
        mapping(address => AgreementRecord) agreements;

        // every Agreement address
        address[] allAgreements;

        // keccak(client, executor) → the active agreement
        // prevents duplicate active deals between one and the same pair
        mapping(bytes32 => address) activePartyPairs;

        // who is allowed to call register() — FactoryFacet only
        // held as the address that is authorized to make the call
        address authorizedFactory;

        // ---- appended 18 September 2026: "an arbiter is not a player in the
        //      market" (the owner's decision of 17 September) ----
        //
        // Per address: how many deals it is a party to that are not finished —
        // ACTIVE or DISPUTED. Both sides of every deal are counted, and the
        // number is what the doors into the arbiter corps read: a man with an
        // unfinished deal may not judge, and a judge may not take one on.
        //
        // WHY IT LIVES HERE, in the registry, and not on a per-person list the
        // door could walk. The clones announce every status change to THIS
        // facet (`updateStatus`, and `syncRegistry` behind it) — so the one
        // place that already learns when a deal ends is the one place that can
        // keep a count at O(1). Clones are nailed to their implementation for
        // life, so a device that needed the CLONE to do anything new would
        // reach only deals created after a new implementation is deployed;
        // this one reaches the ten that exist today.
        //
        // THE DRIFT IT CANNOT RULE OUT, said plainly: `updateStatus` is called
        // by the clone inside a `try` with a gas cap, so a starved or broken
        // call leaves the registry (and this counter) thinking a finished deal
        // is still open. That is not a dead end — `Agreement.syncRegistry()` is
        // callable by ANYONE and pushes the clone's own `status()` through the
        // same door, which is why the counter is moved from the status
        // transition rather than from the finishing call: a repair arrives as a
        // normal transition and is counted exactly once.
        //
        // Zero is the truth for a fresh diamond and NOT for the live one —
        // three deals are DISPUTED on Base Sepolia today, so the cut carries a
        // back-fill (script/MarketPresenceBackfill.sol).
        mapping(address => uint256) openDealCount;

        // ---- appended 18 September 2026: a direct deal is an OFFER, not an
        //      assignment (the owner's decision of the same day) ----
        //
        // Per deal: the named executor has not said yes yet. Set by
        // `registerOffer` — the door the direct hire comes through — and
        // cleared the moment he activates (`notifyOfferAccepted`) or the deal
        // ends without him.
        //
        // WHAT IT IS FOR. `deployAndFund` lets a stranger NAME anybody as the
        // executor of a funded deal. Until this flag existed that alone put an
        // unfinished deal on the named man's record, and the doors into the
        // arbiter corps read exactly that number: a candidate could be shut out
        // for two days by somebody else's transaction, with nothing of his own
        // to withdraw. So the count follows CONSENT, not naming: the client is
        // counted from the first block (he created it and his money is in it),
        // the executor only once he accepts.
        //
        // ⚠️ IT IS ONLY EVER SET FOR DEALS BORN AFTER THE CUT. Clearing it
        // needs the clone to announce the activation, and a clone is nailed to
        // its implementation for life — an older one never announces anything,
        // so a flag set on one of those would leave a LIVE deal uncounted for
        // its executor for ever, which is the hole this rule exists to close,
        // inside out. `registerOffer` is therefore mounted in the same cut as
        // the new implementation and the back-fill does not set this flag for
        // the deals that already exist: their executors stay counted, exactly
        // as they are today.
        mapping(address => bool) offerPending;

        // ---- appended 20 September 2026: the second condition of the
        //      handover — the market is alive RIGHT NOW ----
        //
        // ⚠️ APPENDED AT THE END. The order and the types of the fields above
        // are not touched: this namespace is append-only, enforced by
        // script/check-storage-structs.sh, and a type changed inside an
        // occupied slot is exactly what broke the live JobBoard in July 2026.
        //
        // HOW MANY DEALS ARE OPEN ACROSS THE WHOLE PROTOCOL, not per address.
        // `openDealCount` above answers "what does THIS man still have
        // hanging"; nothing answered "is the market moving at all". The only
        // existing way to ask was `getActive().length + getDisputed().length` —
        // two unbounded loops over a push-only array (see `getActive`), which
        // is fine for a script and impossible inside a door.
        //
        // WHY IT EXISTS. `uniqueActiveUsers` — the first condition of
        // `activateDAO()` — counts every address that EVER earned XP and never
        // goes down. That is deliberate (a handover condition must not flicker)
        // and it is also blind: ten thousand people could have passed through
        // and left, and the number would still say "ready" over a dead market.
        // This field is the half that CAN go down, and it is asked in the same
        // door.
        //
        // MOVED BY THE TRANSITION, not by the finishing call — the same rule
        // and the same reason as `openDealCount`: a clone may push the same
        // terminal status twice (the finishing call, then `syncRegistry`
        // behind a failed first attempt) and a decrement per call would count
        // one ending twice. Both counters therefore move inside the one
        // `wasOpen != nowOpen` branch in `updateStatus`, and adding a third
        // reader later means adding it there and nowhere else.
        //
        // ⚠️ SATURATING ON THE WAY DOWN, for the reason `_closeOpenDeal`
        // saturates: zero is the truth for a fresh diamond and NOT for the live
        // one. Deals already open when this field is mounted were never counted
        // up, so their endings would underflow — and a Panic(0x11) here does not
        // just miscount, it brings down `updateStatus`, which is the door the
        // clone finishes through. The deal would be unable to END. The cut
        // therefore carries a back-fill (the precedent is
        // script/MarketPresenceBackfill.sol) and the saturation is the floor
        // under a back-fill that lands wrong.
        uint256 liveDeals;
    }

    function store() internal pure returns (Layout storage rs) {
        bytes32 position = REGISTRY_STORAGE_POSITION;
        assembly {
            rs.slot := position
        }
    }
}

// ---------- FACET ----------

contract RegistryFacet {
    using RegistryStorage for RegistryStorage.Layout;

    // -------- EVENTS --------

    event AgreementRegistered(
        address indexed agreement,
        address indexed client,
        address indexed executor,
        uint256 amount
    );

    event AgreementStatusUpdated(
        address indexed agreement,
        RegistryStorage.AgreementStatus newStatus
    );

    event AuthorizedFactorySet(address indexed factory);

    /// The executor handed the work in, and a clock is now running against the
    /// client. Emitted BY THE DIAMOND, on the diamond's own address, and that
    /// is the entire reason it exists.
    ///
    /// `markDone()` writes only to the clone and emits `MarkedDone` there,
    /// while the one chain observer the web client is allowed to keep is
    /// pinned to this address. So the transition that starts
    /// AUTO_APPROVE_WINDOW -- the one where the client's silence hands the
    /// whole escrow to the executor two days later -- was the only major
    /// transition in a deal's life the diamond could not see at all.
    ///
    /// WHY NOT `AgreementStatusUpdated(agreement, ACTIVE)`, which would have
    /// needed no new selector and no cut. Two reasons, and the second is
    /// decisive:
    ///
    ///   * the enum above has no member for this, so ACTIVE would have to be
    ///     read as "handed in" by inference rather than by statement, and the
    ///     day something else emitted ACTIVE the meaning would break in
    ///     silence;
    ///   * `Agreement.syncRegistry()` is callable BY ANYONE and already pushes
    ///     exactly ACTIVE for any deal that is not disputed or finished. A
    ///     stranger could therefore ring the client's "your work has arrived"
    ///     bell at will, on a deal where nothing had happened. That is not a
    ///     hypothetical shape -- the selector is mounted and the function takes
    ///     no arguments.
    ///
    /// Carries client and executor for the same reason `AgreementRegistered`
    /// does: an indexed party is a filter the node can apply, so a reader
    /// interested in one person does not have to hold a map of every deal to
    /// find out whether this one is theirs.
    event WorkHandedIn(
        address indexed agreement,
        address indexed client,
        address indexed executor
    );

    /// A direct hire was born as an OFFER: funded, registered, and waiting for
    /// the named executor to say yes (18 September 2026). Emitted by the
    /// diamond next to `AgreementRegistered`, so a reader watching one address
    /// can tell the two roads apart — a deal both sides are already in from a
    /// deal one side has only been named in.
    event OfferPending(
        address indexed agreement,
        address indexed client,
        address indexed executor
    );

    /// The named executor has accepted. From this block the deal is his
    /// unfinished deal too, and the doors into the arbiter corps count it.
    event OfferAccepted(
        address indexed agreement,
        address indexed client,
        address indexed executor
    );

    // -------- ERRORS --------

    error OnlyAuthorizedFactory();
    error OnlyAgreementItself();
    error AgreementNotRegistered();
    error ActiveDealAlreadyExists();
    error RegistryZeroAddress();
    error AlreadyInitialized();
    error NotOwner();

    // -------- MODIFIERS --------

    modifier onlyFactory() {
        if (msg.sender != RegistryStorage.store().authorizedFactory)
            revert OnlyAuthorizedFactory();
        _;
    }

    modifier onlyAgreement(address agreement) {
        // The Agreement identifies itself as msg.sender
        if (msg.sender != agreement) revert OnlyAgreementItself();
        // And it has to be registered for real
        if (RegistryStorage.store().agreements[agreement].agreement != agreement)
            revert AgreementNotRegistered();
        _;
    }

    // -------- INIT (called once, when the Diamond is deployed) --------

    function initRegistry(address factory_) external {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        if (rs.authorizedFactory != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert RegistryZeroAddress();
        // Frontrun protection: the caller has to be the owner of the Diamond
        if (msg.sender != OwnershipLib.contractOwner()) revert NotOwner();
        rs.authorizedFactory = factory_;
        emit AuthorizedFactorySet(factory_);
    }

    // -------- WRITE --------

    /// @notice Registers a new deal both sides are already in. Called only by
    /// FactoryFacet, after the Agreement is deployed.
    ///
    /// "Already in" means the executor has expressed his own consent before
    /// this line: on a job he applied and the client accepted THAT application,
    /// on a service he published the offer and the client took it. The board
    /// paths are those, and they keep counting the deal for both parties from
    /// the first block. The direct hire is not one of them — see
    /// `registerOffer`.
    function register(
        address agreement,
        address client,
        address executor,
        uint256 amount
    ) external onlyFactory {
        _register(agreement, client, executor, amount, true);
    }

    /// @notice Registers a deal whose executor has been NAMED and has not
    /// agreed yet — the direct hire (`FactoryFacet.deployAndFund`).
    ///
    /// Everything about the deal is the same: the escrow is funded, the record
    /// is ACTIVE, the pair is taken, the executor holds his half of the NFT and
    /// may activate for two days. The one difference is the count the arbiter
    /// corps reads — the named man has nothing open until he accepts. See
    /// `Layout.offerPending`.
    function registerOffer(
        address agreement,
        address client,
        address executor,
        uint256 amount
    ) external onlyFactory {
        _register(agreement, client, executor, amount, false);
        RegistryStorage.store().offerPending[agreement] = true;
        emit OfferPending(agreement, client, executor);
    }

    function _register(
        address agreement,
        address client,
        address executor,
        uint256 amount,
        bool executorAccepted
    ) private {
        if (agreement == address(0)) revert RegistryZeroAddress();
        if (client == address(0)) revert RegistryZeroAddress();
        if (executor == address(0)) revert RegistryZeroAddress();

        RegistryStorage.Layout storage rs = RegistryStorage.store();

        bytes32 pairKey = _pairKey(client, executor);

        // One pair cannot hold two active deals at once
        if (rs.activePartyPairs[pairKey] != address(0))
            revert ActiveDealAlreadyExists();

        rs.agreements[agreement] = RegistryStorage.AgreementRecord({
            agreement: agreement,
            client: client,
            executor: executor,
            amount: amount,
            status: RegistryStorage.AgreementStatus.ACTIVE,
            createdAt: block.timestamp,
            resolvedAt: 0
        });

        rs.allAgreements.push(agreement);
        rs.activePartyPairs[pairKey] = agreement;
        // A new deal is open for the client from the first block: he created it
        // and his money is inside it, and that is true of the direct hire as
        // much as of a board deal. The status it is born with is ACTIVE, so
        // this is the same statement `_isOpenStatus` makes below — written here
        // rather than derived, because `_register` is the only place a record
        // appears at all.
        rs.openDealCount[client]++;
        // The executor is counted on his CONSENT. On every board road he gave
        // it before this line; on the direct hire he has only been named, and
        // naming a man is not something he can be held to. See
        // `Layout.offerPending`.
        if (executorAccepted) rs.openDealCount[executor]++;
        // One DEAL, not one party: this counter is the market's, not a
        // person's, so it moves once here however many people the deal counted.
        rs.liveDeals++;

        emit AgreementRegistered(agreement, client, executor, amount);
    }

    /// @notice Updates the status. Called only by the Agreement contract itself.
    function updateStatus(
        address agreement,
        RegistryStorage.AgreementStatus newStatus
    ) external onlyAgreement(agreement) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        RegistryStorage.AgreementRecord storage record = rs.agreements[agreement];

        // The parties' open-deal counters are moved by the TRANSITION, not by
        // the new status: a clone may push the same terminal status twice (the
        // finishing call, and then `syncRegistry` behind a failed first
        // attempt), and a decrement per call would count one ending twice.
        // Asked in both directions on purpose — nothing today drives a
        // finished deal back to ACTIVE or DISPUTED, and if something ever does,
        // the count follows it instead of standing one short for ever.
        bool wasOpen = _isOpenStatus(record.status);
        bool nowOpen = _isOpenStatus(newStatus);
        if (wasOpen != nowOpen) {
            // An offer nobody accepted is counted for the CLIENT only, so only
            // the client's count may be given back when it ends. Decrementing
            // the named executor here would take a unit off a number he never
            // got one from, and `_closeOpenDeal` saturates in silence: the loss
            // would land on some OTHER deal of his and show up as a man who can
            // never become an arbiter, with nothing on record explaining why.
            //
            // The flag is cleared either way — a deal that has ended has no
            // offer standing on it, and `notifyOfferAccepted` must not be able
            // to count anybody into a finished deal afterwards.
            bool pendingOffer = rs.offerPending[agreement];
            if (pendingOffer) delete rs.offerPending[agreement];

            if (nowOpen) {
                rs.openDealCount[record.client]++;
                if (!pendingOffer) rs.openDealCount[record.executor]++;
                rs.liveDeals++;
            } else {
                _closeOpenDeal(rs, record.client);
                if (!pendingOffer) _closeOpenDeal(rs, record.executor);
                // Saturating, and for a harder reason than the per-party
                // counter's: this door is how a clone ENDS. An underflow here
                // would revert `updateStatus` for a deal that was open before
                // the field was mounted, and the deal could never reach a
                // terminal status at all. See `Layout.liveDeals`.
                if (rs.liveDeals != 0) rs.liveDeals--;
            }
        }

        record.status = newStatus;

        // Once the deal is closed, drop it from the active pairs
        if (newStatus != RegistryStorage.AgreementStatus.ACTIVE) {
            bytes32 pairKey = _pairKey(record.client, record.executor);
            if (rs.activePartyPairs[pairKey] == agreement) {
                delete rs.activePartyPairs[pairKey];
            }
            record.resolvedAt = block.timestamp;
        }

        emit AgreementStatusUpdated(agreement, newStatus);
    }

    /// @notice The Agreement announces that its executor has handed the work in.
    ///
    /// THE CALLER IS THE KEY. No `agreement` argument, so there is none to pass
    /// wrongly and none for a stranger to point at somebody else's deal: the
    /// only address this function can name is the one that called it, and it
    /// must already be in the registry. Same shape, and the same argument, as
    /// `ArbiterRegistryFacet.creditDisputeFee`.
    ///
    /// WRITES NOTHING, on purpose. The clone holds `_markedDoneAt` and is the
    /// authority on it; a copy here would be a second number free to disagree
    /// with the first, and it would cost a cold SSTORE on every hand-in to
    /// create that disagreement. The status stays ACTIVE because the deal IS
    /// still active -- a handed-in deal can still be disputed, released, or
    /// left to auto-approve -- and moving it out of ACTIVE would drop the pair
    /// from `activePartyPairs` and stamp `resolvedAt` on a deal that has not
    /// resolved.
    ///
    /// A second call therefore changes no state and costs the caller gas.
    /// `markDone()` refuses a second run (`AlreadyMarkedDone`), so a second
    /// call cannot come from an honest clone at all; from a dishonest one it
    /// buys a duplicate log entry and nothing else.
    function notifyWorkHandedIn() external {
        RegistryStorage.AgreementRecord storage record =
            RegistryStorage.store().agreements[msg.sender];
        if (record.agreement != msg.sender) revert AgreementNotRegistered();

        emit WorkHandedIn(msg.sender, record.client, record.executor);
    }

    /// @notice The named executor has accepted the offer — announced by the
    /// deal itself, from inside `activate()`.
    ///
    /// This is the line where a direct hire stops being somebody else's idea
    /// and becomes the executor's own unfinished deal, so it is the line the
    /// count moves on. Shaped exactly like `notifyWorkHandedIn` above: no
    /// arguments, the clone is `msg.sender`, and the record proves it is a real
    /// deal of this protocol.
    ///
    /// IDEMPOTENT AND HARMLESS ON EVERY OTHER ROAD. A board deal has no offer
    /// pending, so the call finds the flag clear and changes nothing — which is
    /// what lets the implementation announce every activation without knowing
    /// which road it was born on. A second announcement on the same deal does
    /// nothing either.
    ///
    /// ⚠️ IT MUST NOT REVERT ON A DEAL IT HAS NOTHING TO DO WITH. The clone
    /// calls it inside a gas-capped `try`, so a revert would be swallowed in
    /// silence anyway — but a revert here on the ordinary road would put the
    /// whole device one starved call away from a live deal nobody counts, which
    /// is the hole the rule exists to close.
    function notifyOfferAccepted() external {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        RegistryStorage.AgreementRecord storage record = rs.agreements[msg.sender];
        if (record.agreement != msg.sender) revert AgreementNotRegistered();

        if (!rs.offerPending[msg.sender]) return;
        delete rs.offerPending[msg.sender];

        // Counted only while the deal is actually unfinished — the same pair of
        // statuses `_isOpenStatus` names. An activation cannot arrive on a
        // finished deal (the clone refuses), and if one ever did, this would
        // add a unit nothing takes back.
        if (_isOpenStatus(record.status)) rs.openDealCount[record.executor]++;

        emit OfferAccepted(msg.sender, record.client, record.executor);
    }

    /// @notice Updates the Factory address (owner of the Diamond only)
    /// Needed when a new version of FactoryFacet is deployed
    function setAuthorizedFactory(address newFactory) external {
        if (msg.sender != OwnershipLib.contractOwner()) revert NotOwner();
        if (newFactory == address(0)) revert RegistryZeroAddress();
        RegistryStorage.store().authorizedFactory = newFactory;
        emit AuthorizedFactorySet(newFactory);
    }

    // -------- READ --------

    /// @notice Whether this pair has an active deal
    function hasActivePair(address client, address executor) external view returns (bool) {
        return RegistryStorage.store().activePartyPairs[_pairKey(client, executor)] != address(0);
    }

    /// @notice Address of the pair's active deal (address(0) if there is none)
    function getActivePair(address client, address executor) external view returns (address) {
        return RegistryStorage.store().activePartyPairs[_pairKey(client, executor)];
    }

    /// @notice The full record for an Agreement address
    function getRecord(address agreement) external view returns (RegistryStorage.AgreementRecord memory) {
        return RegistryStorage.store().agreements[agreement];
    }

    /// @notice Every deal of a client
    function getByClient(address client) external view returns (RegistryStorage.AgreementRecord[] memory) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        return _filter(rs, client, true);
    }

    /// @notice Every deal of an executor
    function getByExecutor(address executor) external view returns (RegistryStorage.AgreementRecord[] memory) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        return _filter(rs, executor, false);
    }

    /// @notice Every active deal (for the board)
    function getActive() external view returns (RegistryStorage.AgreementRecord[] memory) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        uint256 count;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            if (rs.agreements[rs.allAgreements[i]].status == RegistryStorage.AgreementStatus.ACTIVE) {
                count++;
            }
        }
        RegistryStorage.AgreementRecord[] memory result = new RegistryStorage.AgreementRecord[](count);
        uint256 idx;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            if (rs.agreements[rs.allAgreements[i]].status == RegistryStorage.AgreementStatus.ACTIVE) {
                result[idx++] = rs.agreements[rs.allAgreements[i]];
            }
        }
        return result;
    }

    /// @notice Every disputed deal (for the arbiters' board)
    function getDisputed() external view returns (RegistryStorage.AgreementRecord[] memory) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        uint256 count;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            if (rs.agreements[rs.allAgreements[i]].status == RegistryStorage.AgreementStatus.DISPUTED) {
                count++;
            }
        }
        RegistryStorage.AgreementRecord[] memory result = new RegistryStorage.AgreementRecord[](count);
        uint256 idx;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            if (rs.agreements[rs.allAgreements[i]].status == RegistryStorage.AgreementStatus.DISPUTED) {
                result[idx++] = rs.agreements[rs.allAgreements[i]];
            }
        }
        return result;
    }

    /// @notice Total number of deals
    function totalAgreements() external view returns (uint256) {
        return RegistryStorage.store().allAgreements.length;
    }

    /// @notice Address of the authorized Factory
    function authorizedFactory() external view returns (address) {
        return RegistryStorage.store().authorizedFactory;
    }

    // -------- INTERNAL --------

    /// Is a deal in this status still unfinished? ACTIVE and DISPUTED are; the
    /// three terminal ones are not.
    ///
    /// DISPUTED counts as open although it is already out of `activePartyPairs`
    /// — the pair table is about "may these two be matched again", and a
    /// dispute answers no for a different reason than an ending does. A
    /// disputed deal has money in escrow and a verdict to come, which is
    /// precisely the deal an arbiter must not be a party to.
    function _isOpenStatus(RegistryStorage.AgreementStatus s) internal pure returns (bool) {
        return s == RegistryStorage.AgreementStatus.ACTIVE
            || s == RegistryStorage.AgreementStatus.DISPUTED;
    }

    /// ⚠️ SATURATING. Deals registered before this counter existed never
    /// incremented it, and this function is reached from a clone's `_complete`
    /// — inside a `try`, but also from `syncRegistry`, which has no `try` at
    /// all. A Panic(0x11) there would make `syncRegistry` unusable for that
    /// deal for ever, and that call is the repair path for a registry that
    /// drifted. The cut back-fills the three live open deals so the clamp is
    /// not reached in the steady state.
    function _closeOpenDeal(RegistryStorage.Layout storage rs, address party) internal {
        uint256 c = rs.openDealCount[party];
        if (c != 0) rs.openDealCount[party] = c - 1;
    }

    /// @notice How many unfinished deals this address is a party to — the
    ///         number the doors into the arbiter corps read.
    function getOpenDealCount(address party) external view returns (uint256) {
        return RegistryStorage.store().openDealCount[party];
    }

    /// @notice Is this deal a direct hire whose named executor has not accepted
    ///         it yet? While it is, the deal is on the client's record and not
    ///         on his.
    function isOfferPending(address agreement) external view returns (bool) {
        return RegistryStorage.store().offerPending[agreement];
    }

    /// @notice How many deals are open across the whole protocol right now.
    ///
    /// ACTIVE plus DISPUTED — the same definition `_isOpenStatus` uses, which
    /// is what makes this number the O(1) twin of
    /// `getActive().length + getDisputed().length` and not an opinion of its
    /// own. One of the two halves of the handover's liveness condition; the
    /// door reads the field, this reads the same field, and
    /// `getHandoverReadiness()` puts it beside the floor it has to clear.
    function getLiveDeals() external view returns (uint256) {
        return RegistryStorage.store().liveDeals;
    }

    /// @notice Anyone may push a deal's own answer to "has the executor
    ///         started?" through the same door the clone announces it at.
    ///
    /// This is the repair path for the one drift `notifyOfferAccepted` has. The
    /// clone announces the activation inside a gas-capped `try`, so a starved
    /// or unreachable call leaves a LIVE deal off the executor's record — and
    /// that record is what the doors into the arbiter corps read, so the drift
    /// points the wrong way: it would let a man judge while holding a deal. The
    /// cure is the one `Agreement.syncRegistry()` already uses for the status:
    /// read the clone's own state and push it, callable by anybody, so nobody
    /// has to be trusted to have succeeded.
    ///
    /// A clone that cannot answer `activatedAt()` is left alone rather than
    /// guessed about — the same rule as `appealDepositFor`: a short reply must
    /// not become a panic, and a silent one must not become a verdict.
    function syncOfferAcceptance(address agreement) external {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        if (rs.agreements[agreement].agreement != agreement) revert AgreementNotRegistered();
        if (!rs.offerPending[agreement]) return;

        (bool ok, bytes memory ret) =
            agreement.staticcall(abi.encodeWithSignature("activatedAt()"));
        if (!ok || ret.length < 32) return;
        if (abi.decode(ret, (uint256)) == 0) return;

        delete rs.offerPending[agreement];
        RegistryStorage.AgreementRecord storage record = rs.agreements[agreement];
        if (_isOpenStatus(record.status)) rs.openDealCount[record.executor]++;

        emit OfferAccepted(agreement, record.client, record.executor);
    }

    function _pairKey(address client, address executor) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(client, executor));
    }

    function _filter(
        RegistryStorage.Layout storage rs,
        address party,
        bool isClient
    ) internal view returns (RegistryStorage.AgreementRecord[] memory) {
        uint256 count;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            RegistryStorage.AgreementRecord storage rec = rs.agreements[rs.allAgreements[i]];
            if (isClient ? rec.client == party : rec.executor == party) count++;
        }
        RegistryStorage.AgreementRecord[] memory result = new RegistryStorage.AgreementRecord[](count);
        uint256 idx;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            RegistryStorage.AgreementRecord storage rec = rs.agreements[rs.allAgreements[i]];
            if (isClient ? rec.client == party : rec.executor == party) {
                result[idx++] = rec;
            }
        }
        return result;
    }
}
