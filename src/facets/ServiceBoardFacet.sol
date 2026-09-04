// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — ServiceBoardFacet.sol
// Service marketplace: executor posts → client requests →
//                       executor accepts/rejects → Agreement
//
// Symmetric two-sided flow:
//   mintService():    executor pays the flat anti-spam floor → feeRecipient
//   requestService(): client pays amount + percentage (quote()); the percentage
//                     is held in the Diamond — there is no deal to send it to yet
//   acceptRequest():  executor accepts → amount into Agreement, the held
//                     percentage → feeRecipient (the fee is earned). It also
//                     supersedes (SUPERSEDED) every other PENDING request from
//                     this client to this executor — the same refund as on
//                     reject/cancel, the floor likewise burns to feeRecipient
//   rejectRequest():  executor rejects → amount + percentage above the floor is
//                     refunded to client, the floor burns to feeRecipient
//   cancelRequest():  client cancels (while PENDING) → the same refund as reject
//
// The fee is pushed to the recipient, but a person getting their money out does
// NOT depend on that: on refusal the amount is booked as a debt in
// FactoryStorage.undeliveredFee and pulled later through
// FactoryFacet.withdrawUndeliveredFees(). The rationale and the single
// implementation of the rule live in FactoryStorage.settleFee.
//
// One exception, stated out loud: mintService()/mintServiceWithPermit() pay the
// floor straight from the executor's wallet to feeRecipient, bypassing the
// diamond. A refusal there fails the whole posting — and that is right: the
// executor's money stays with the executor, there is nothing to lock in.
// ============================================================

import "../FactoryFacet.sol";
import "../DiamondProxy.sol";
import "./IFactory.sol";

// ---------- STORAGE ----------

library ServiceBoardStorage {
    /// @custom:storage-location erc7201:hexseal.serviceboard.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.serviceboard.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant POSITION = 0x46cd88da19a0b25b4baeccf5bdf5b6735146dba41575547a28d877fa2b430000;

    enum ServiceStatus { ACTIVE, PAUSED, REMOVED }
    enum RequestStatus { PENDING, ACCEPTED, REJECTED, CANCELLED, SUPERSEDED }

    struct Service {
        address executor;
        string title;           // max 100 chars
        string description;     // max 500 chars
        uint256 price;          // suggested price in USDC (6 decimals)
        uint256 deadlineDays;
        uint8 region;
        ServiceStatus status;
        uint256 createdAt;
        uint256 hiresCount;     // how many requests were accepted
    }

    struct HireRequest {
        address client;
        uint256 serviceId;
        uint256 amount;         // deal amount (locked in the Diamond by client)
        uint256 deadlineDays;
        string  terms;
        uint8 region;
        RequestStatus status;
        uint256 createdAt;
        address agreement;      // Agreement address after acceptRequest
    }

    struct Layout {
        // Services
        uint256 nextServiceId;
        mapping(uint256 => Service) services;
        mapping(address => uint256[]) executorServices;
        mapping(uint256 => address[]) serviceClients;   // legacy, superseded by requests

        // HireRequests (added in this upgrade, slots 4-8)
        uint256 nextRequestId;
        mapping(uint256 => HireRequest) requests;
        mapping(uint256 => uint256[]) serviceRequests;  // serviceId → requestIds
        mapping(address => uint256[]) clientRequests;   // client → requestIds
        mapping(uint256 => uint256) requestFunds;       // requestId → USDC locked in Diamond

        // Bounded list of currently-PENDING request IDs per (client, executor) pair —
        // NOT a full history (that only ever grows). Used by acceptRequest() to find
        // and auto-refund sibling requests that can never be accepted once one from
        // this pair is accepted (hasActivePair blocks them forever after).
        mapping(address => mapping(address => uint256[])) pendingRequestIdsByClientAndExecutor;

        // Fee held against each request. Forwarded to the treasury on
        // acceptRequest, refunded (except the floor) on reject/cancel/supersede.
        mapping(uint256 => uint256) requestFeeHeld;

        // How many of this client's requests sit in PENDING — across ALL
        // executors. MAX_PENDING_PER_PAIR caps a single pair only, which a
        // fan-out walks around; this counter is what closes the fan-out.
        mapping(address => uint256) pendingRequestCount;
    }

    function store() internal pure returns (Layout storage s) {
        bytes32 p = POSITION;
        assembly { s.slot := p }
    }
}

// USDC permit interface (EIP-2612)
interface IServiceBoardUSDC {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

// ---------- FACET ----------

contract ServiceBoardFacet {

    // -------- EVENTS --------

    event ServicePosted(uint256 indexed serviceId, address indexed executor, uint256 price, uint8 region, string title, string description, uint256 deadlineDays);
    event ServiceRemoved(uint256 indexed serviceId, address indexed executor);
    event ServicePaused(uint256 indexed serviceId);
    event ServiceUnpaused(uint256 indexed serviceId);
    event ServiceEdited(uint256 indexed serviceId, address indexed executor, string title, string description, uint256 price, uint256 deadlineDays, uint8 region);
    event ServiceRequested(uint256 indexed requestId, uint256 indexed serviceId, address indexed client, uint256 amount);
    event RequestAccepted(uint256 indexed requestId, address indexed executor, address indexed client, address agreement);
    event RequestRejected(uint256 indexed requestId, address indexed executor, address indexed client);
    event RequestCancelled(uint256 indexed requestId, address indexed client);
    event RequestSuperseded(uint256 indexed requestId, address indexed client, address indexed executor, uint256 refundAmount);
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
    ///                        direct hire through
    ///                        FactoryFacet.deployAgreement/deployAndFund,
    ///                        bypassing both boards; the deal is recognised by
    ///                        the AgreementDeployed of the same transaction —
    ///                        the same way the subgraph already ties
    ///                        RequestAccepted to AgreementDeployed by transaction.
    event FeeCollected(uint256 indexed id, address indexed payer, uint8 indexed kind, uint256 amount);

    /// The same fee, earned the same way, that `feeRecipient` would not take.
    /// Same fields as `FeeCollected` on purpose, so the two can be joined by
    /// `(id, kind)` — but a DIFFERENT event, because `FeeCollected` means "this
    /// much reached the treasury in this transaction" and is what the subgraph
    /// counts as protocol revenue. Emitting it for money that never left the
    /// diamond would make the revenue figure a claim about intent.
    ///
    /// The debt itself lives in `FactoryStorage.undeliveredFee` and is read
    /// with `FactoryFacet.getUndeliveredFees()`; this event says WHICH request
    /// and WHOSE dollar, which the running total cannot.
    event FeeDeferred(uint256 indexed id, address indexed payer, uint8 indexed kind, uint256 amount);

    uint8 constant FEE_KIND_SERVICE_LISTING = 2;
    uint8 constant FEE_KIND_REQUEST_DEAL = 3;
    uint8 constant FEE_KIND_REQUEST_FORFEIT = 4;

    // -------- ERRORS --------

    error TitleInvalid();
    error DescriptionTooLong();
    error ZeroAmount();
    error DeadlineInvalid();
    error InvalidRegion();
    error NotExecutor();
    error NotClient();
    error ServiceNotActive();
    error RequestNotPending();
    error Reentrant();
    error FactoryPaused();
    error SelfRequest();
    error ActiveDealExists();
    error TooManyPendingRequests();

    // -------- REENTRANCY --------

    modifier nonReentrant() {
        if (DiamondGuard.status() == DiamondGuard.ENTERED) revert Reentrant();
        DiamondGuard.setStatus(DiamondGuard.ENTERED);
        _;
        DiamondGuard.setStatus(DiamondGuard.NOT_ENTERED);
    }

    modifier whenNotPaused() {
        // Reads the brake's clock, not the dead `paused` bool it used to read.
        // The bool has had no writer since 24 June 2026, so this modifier stood
        // on nine money doors for ten weeks looking like a working guard and
        // being an ornament. The rule itself lives in FactoryStorage — one
        // implementation, called from all three facets, because two readings of
        // "is it braked" that drift apart give a protocol braked at one door
        // and open at the next.
        if (FactoryStorage.newDealsPaused(FactoryStorage.store())) revert FactoryPaused();
        _;
    }

    // -------- ERC-2771 msgSender --------

    function _msgSender() internal view returns (address sender) {
        if (
            msg.sender == FactoryStorage.store().trustedForwarder &&
            msg.data.length >= 20
        ) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    // -------- EXECUTOR: POST SERVICE --------

    /// @notice Executor posts a service — gasless-compatible (ERC-2771).
    /// @dev On the gasless path the relayer calls USDC.permit() separately before the ForwardRequest.
    ///      The direct path requires approve(diamond, fee) before the call.
    function mintService(
        string memory title,
        string memory description,
        uint256 price,
        uint256 deadlineDays,
        uint8 region
    ) external nonReentrant whenNotPaused returns (uint256 serviceId) {
        address executor = _msgSender();

        uint256 titleLen = bytes(title).length;
        if (titleLen == 0 || titleLen > 100) revert TitleInvalid();
        if (bytes(description).length > 500) revert DescriptionTooLong();
        if (deadlineDays == 0 || deadlineDays > 365) revert DeadlineInvalid();
        if (region > 6) revert InvalidRegion();

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        // Posting a service: there is no deal amount yet, nothing to take a
        // percentage of. Exactly the anti-spam floor is paid, and it is not refunded.
        uint256 fee = fs.feeFloor;
        if (fee == 0) revert FeeNotConfigured();

        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        serviceId = s.nextServiceId++;

        s.services[serviceId] = ServiceBoardStorage.Service({
            executor:    executor,
            title:       title,
            description: description,
            price:       price,
            deadlineDays: deadlineDays,
            region:      region,
            status:      ServiceBoardStorage.ServiceStatus.ACTIVE,
            createdAt:   block.timestamp,
            hiresCount:  0
        });
        s.executorServices[executor].push(serviceId);

        // Anti-spam fee → feeRecipient (not refunded)
        _safeTransferFrom(fs.usdc, executor, fs.feeRecipient, fee);
        emit FeeCollected(serviceId, executor, FEE_KIND_SERVICE_LISTING, fee);

        emit ServicePosted(serviceId, executor, price, region, title, description, deadlineDays);
    }

    /// @notice Gasless variant of mintService with EIP-2612 permit (one call, no prior approve).
    /// @dev executor is passed explicitly — msg.sender here is the forwarder (ERC-2771).
    function mintServiceWithPermit(
        address executor,
        string memory title,
        string memory description,
        uint256 price,
        uint256 deadlineDays,
        uint8 region,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused returns (uint256 serviceId) {
        uint256 titleLen = bytes(title).length;
        if (titleLen == 0 || titleLen > 100) revert TitleInvalid();
        if (bytes(description).length > 500) revert DescriptionTooLong();
        if (deadlineDays == 0 || deadlineDays > 365) revert DeadlineInvalid();
        if (region > 6) revert InvalidRegion();

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        // Posting a service: there is no deal amount yet, nothing to take a
        // percentage of. Exactly the anti-spam floor is paid, and it is not refunded.
        uint256 fee = fs.feeFloor;
        if (fee == 0) revert FeeNotConfigured();

        IServiceBoardUSDC(fs.usdc).permit(executor, address(this), fee, permitDeadline, v, r, s);

        ServiceBoardStorage.Layout storage sbl = ServiceBoardStorage.store();
        serviceId = sbl.nextServiceId++;

        sbl.services[serviceId] = ServiceBoardStorage.Service({
            executor:    executor,
            title:       title,
            description: description,
            price:       price,
            deadlineDays: deadlineDays,
            region:      region,
            status:      ServiceBoardStorage.ServiceStatus.ACTIVE,
            createdAt:   block.timestamp,
            hiresCount:  0
        });
        sbl.executorServices[executor].push(serviceId);

        _safeTransferFrom(fs.usdc, executor, fs.feeRecipient, fee);
        emit FeeCollected(serviceId, executor, FEE_KIND_SERVICE_LISTING, fee);

        emit ServicePosted(serviceId, executor, price, region, title, description, deadlineDays);
    }

    function removeService(uint256 serviceId) external {
        address sender = _msgSender();
        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        ServiceBoardStorage.Service storage svc = s.services[serviceId];

        if (sender != svc.executor) revert NotExecutor();
        if (svc.status == ServiceBoardStorage.ServiceStatus.REMOVED) revert ServiceNotActive();

        svc.status = ServiceBoardStorage.ServiceStatus.REMOVED;
        emit ServiceRemoved(serviceId, sender);
    }

    function pauseService(uint256 serviceId) external {
        address sender = _msgSender();
        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        ServiceBoardStorage.Service storage svc = s.services[serviceId];

        if (sender != svc.executor) revert NotExecutor();
        if (svc.status != ServiceBoardStorage.ServiceStatus.ACTIVE) revert ServiceNotActive();

        svc.status = ServiceBoardStorage.ServiceStatus.PAUSED;
        emit ServicePaused(serviceId);
    }

    function unpauseService(uint256 serviceId) external {
        address sender = _msgSender();
        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        ServiceBoardStorage.Service storage svc = s.services[serviceId];

        if (sender != svc.executor) revert NotExecutor();
        if (svc.status != ServiceBoardStorage.ServiceStatus.PAUSED) revert ServiceNotActive();

        svc.status = ServiceBoardStorage.ServiceStatus.ACTIVE;
        emit ServiceUnpaused(serviceId);
    }

    /// @notice Executor edits a service (gasless-compatible).
    /// @dev Allowed for ACTIVE and PAUSED services (not for REMOVED).
    ///      Safe even with PENDING requests outstanding: every request pins its
    ///      own terms (amount/deadline) independently of the service fields.
    function editService(
        uint256 serviceId,
        string memory title,
        string memory description,
        uint256 price,
        uint256 deadlineDays,
        uint8 region
    ) external whenNotPaused {
        address sender = _msgSender();
        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        ServiceBoardStorage.Service storage svc = s.services[serviceId];

        if (sender != svc.executor) revert NotExecutor();
        if (svc.status == ServiceBoardStorage.ServiceStatus.REMOVED) revert ServiceNotActive();

        // --- Validation (the same as on mint) ---
        uint256 titleLen = bytes(title).length;
        if (titleLen == 0 || titleLen > 100) revert TitleInvalid();
        if (bytes(description).length > 500) revert DescriptionTooLong();
        if (deadlineDays == 0 || deadlineDays > 365) revert DeadlineInvalid();
        if (region > 6) revert InvalidRegion();

        // --- Effects ---
        svc.title        = title;
        svc.description  = description;
        svc.price        = price;
        svc.deadlineDays = deadlineDays;
        svc.region       = region;

        emit ServiceEdited(serviceId, sender, title, description, price, deadlineDays, region);
    }

    // -------- CLIENT: REQUEST SERVICE --------

    uint256 constant MAX_PENDING_PER_PAIR = 20;

    /// @notice Client requests a hire — gasless-compatible (ERC-2771).
    /// @dev On the gasless path the relayer calls USDC.permit() separately before the ForwardRequest.
    ///      The direct path requires approve(diamond, amount + fee) before the call.
    ///      The fee (quote(amount)) is held in the Diamond instead of forwarded —
    ///      there is no deal yet. It leaves for feeRecipient on acceptRequest, and
    ///      comes back (except the floor) on reject/cancel/supersede.
    function requestService(
        uint256 serviceId,
        uint256 amount,
        uint256 deadlineDays,
        string  calldata terms,
        uint8 region
    ) external nonReentrant whenNotPaused returns (uint256 requestId) {
        address client = _msgSender();

        if (amount == 0) revert ZeroAmount();
        if (deadlineDays == 0 || deadlineDays > 365) revert DeadlineInvalid();
        if (region > 6) revert InvalidRegion();

        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        ServiceBoardStorage.Service storage svc = s.services[serviceId];

        if (svc.status != ServiceBoardStorage.ServiceStatus.ACTIVE) revert ServiceNotActive();
        if (client == svc.executor) revert SelfRequest();

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        if (IRegistry(fs.diamond).hasActivePair(client, svc.executor)) revert ActiveDealExists();
        if (s.pendingRequestIdsByClientAndExecutor[client][svc.executor].length >= MAX_PENDING_PER_PAIR) revert TooManyPendingRequests();

        uint256 cap = fs.maxPendingRequests;
        if (cap != 0 && s.pendingRequestCount[client] >= cap) revert TooManyPendingRequests();

        uint256 fee = FactoryStorage.quote(fs, amount);

        requestId = s.nextRequestId++;

        s.requests[requestId] = ServiceBoardStorage.HireRequest({
            client:       client,
            serviceId:    serviceId,
            amount:       amount,
            deadlineDays: deadlineDays,
            terms:        terms,
            region:       region,
            status:       ServiceBoardStorage.RequestStatus.PENDING,
            createdAt:    block.timestamp,
            agreement:    address(0)
        });
        s.serviceRequests[serviceId].push(requestId);
        s.clientRequests[client].push(requestId);
        s.pendingRequestIdsByClientAndExecutor[client][svc.executor].push(requestId);

        // Amount + fee → Diamond. The fee is held: it leaves for the treasury on
        // acceptRequest, and comes back (except the floor) on reject/cancel.
        _safeTransferFrom(fs.usdc, client, address(this), amount + fee);
        s.requestFunds[requestId]   = amount;
        s.requestFeeHeld[requestId] = fee;
        s.pendingRequestCount[client]++;

        emit ServiceRequested(requestId, serviceId, client, amount);
    }

    /// @notice Gasless variant of requestService with EIP-2612 permit.
    /// @dev client is passed explicitly — msg.sender here is the forwarder (ERC-2771).
    function requestServiceWithPermit(
        address client,
        uint256 serviceId,
        uint256 amount,
        uint256 deadlineDays,
        string  calldata terms,
        uint8   region,
        uint256 permitDeadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (amount == 0) revert ZeroAmount();
        if (deadlineDays == 0 || deadlineDays > 365) revert DeadlineInvalid();
        if (region > 6) revert InvalidRegion();

        ServiceBoardStorage.Layout storage st = ServiceBoardStorage.store();
        ServiceBoardStorage.Service storage svc = st.services[serviceId];

        if (svc.status != ServiceBoardStorage.ServiceStatus.ACTIVE) revert ServiceNotActive();
        if (client == svc.executor) revert SelfRequest();

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        if (IRegistry(fs.diamond).hasActivePair(client, svc.executor)) revert ActiveDealExists();
        if (st.pendingRequestIdsByClientAndExecutor[client][svc.executor].length >= MAX_PENDING_PER_PAIR) revert TooManyPendingRequests();

        uint256 cap = fs.maxPendingRequests;
        if (cap != 0 && st.pendingRequestCount[client] >= cap) revert TooManyPendingRequests();

        uint256 fee = FactoryStorage.quote(fs, amount);

        IServiceBoardUSDC(fs.usdc).permit(client, address(this), amount + fee, permitDeadline, v, r, s);

        requestId = st.nextRequestId++;

        st.requests[requestId] = ServiceBoardStorage.HireRequest({
            client:       client,
            serviceId:    serviceId,
            amount:       amount,
            deadlineDays: deadlineDays,
            terms:        terms,
            region:       region,
            status:       ServiceBoardStorage.RequestStatus.PENDING,
            createdAt:    block.timestamp,
            agreement:    address(0)
        });
        st.serviceRequests[serviceId].push(requestId);
        st.clientRequests[client].push(requestId);
        st.pendingRequestIdsByClientAndExecutor[client][svc.executor].push(requestId);

        _safeTransferFrom(fs.usdc, client, address(this), amount + fee);
        st.requestFunds[requestId]   = amount;
        st.requestFeeHeld[requestId] = fee;
        st.pendingRequestCount[client]++;

        emit ServiceRequested(requestId, serviceId, client, amount);
    }

    // -------- EXECUTOR: ACCEPT / REJECT --------

    /// @notice Executor accepts a request → deploys the Agreement, moves amount out of the Diamond.
    function acceptRequest(uint256 requestId)
        external nonReentrant whenNotPaused returns (address agreementAddr)
    {
        address sender = _msgSender();
        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        ServiceBoardStorage.HireRequest storage req = s.requests[requestId];
        ServiceBoardStorage.Service storage svc = s.services[req.serviceId];

        if (sender != svc.executor) revert NotExecutor();
        if (req.status != ServiceBoardStorage.RequestStatus.PENDING) revert RequestNotPending();

        // Effects first
        req.status = ServiceBoardStorage.RequestStatus.ACCEPTED;
        _decrementPendingCount(s, req.client);
        svc.hiresCount++;

        uint256 held = s.requestFunds[requestId];
        s.requestFunds[requestId] = 0;

        address client   = req.client;
        uint256 amount   = req.amount;
        uint256 deadline = req.deadlineDays;
        string memory terms = req.terms;
        uint8   region   = req.region;

        // Deploy Agreement through the Factory
        (bool ok, bytes memory ret) = address(this).call(
            abi.encodeWithSelector(
                IFactory.deployAgreement.selector,
                client,
                sender,
                address(0),
                amount,
                deadline,
                terms,
                region
            )
        );
        require(ok, "ServiceBoard: deploy failed");
        agreementAddr = abi.decode(ret, (address));

        req.agreement = agreementAddr;

        // Amount out of the Diamond → Agreement
        FactoryStorage.Layout storage fs = FactoryStorage.store();
        _safeTransfer(fs.usdc, agreementAddr, held);

        // The deal exists — the fee is earned. If it does not arrive it becomes a
        // debt to the protocol, not a reason to undo the hire: the client's money
        // is already in the Agreement, and a revert on this line would put it back
        // in the diamond, where withdrawing the request would hit that same
        // transfer all over again.
        uint256 feeHeld = s.requestFeeHeld[requestId];
        s.requestFeeHeld[requestId] = 0;
        _settleFee(fs, requestId, client, FEE_KIND_REQUEST_DEAL, feeHeld);

        // Activate the Agreement
        (bool funded, ) = agreementAddr.call(abi.encodeWithSignature("fundFromFactory()"));
        require(funded, "ServiceBoard: fund failed");

        emit RequestAccepted(requestId, sender, client, agreementAddr);

        // Any other PENDING request from this same client to this same executor can
        // never be accepted now (hasActivePair blocks it) — refund and mark it
        // SUPERSEDED so it doesn't sit stuck forever.
        uint256[] storage siblings = s.pendingRequestIdsByClientAndExecutor[client][sender];
        for (uint256 i = 0; i < siblings.length; i++) {
            uint256 siblingId = siblings[i];
            if (siblingId == requestId) continue;
            ServiceBoardStorage.HireRequest storage siblingReq = s.requests[siblingId];
            if (siblingReq.status != ServiceBoardStorage.RequestStatus.PENDING) continue;
            siblingReq.status = ServiceBoardStorage.RequestStatus.SUPERSEDED;
            _decrementPendingCount(s, client);
            uint256 siblingRefund = s.requestFunds[siblingId];
            s.requestFunds[siblingId] = 0;

            uint256 siblingFee = s.requestFeeHeld[siblingId];
            s.requestFeeHeld[siblingId] = 0;
            uint256 siblingFloor = fs.feeFloor;
            uint256 siblingBurned = siblingFee < siblingFloor ? siblingFee : siblingFloor;

            uint256 siblingTotal = siblingRefund + (siblingFee - siblingBurned);
            if (siblingTotal > 0) _safeTransfer(fs.usdc, client, siblingTotal);
            _settleFee(fs, siblingId, client, FEE_KIND_REQUEST_FORFEIT, siblingBurned);
            // RequestSuperseded has to carry the amount actually transferred
            // (refund + fee above the floor), not the deal body alone.
            emit RequestSuperseded(siblingId, client, sender, siblingTotal);
        }
        delete s.pendingRequestIdsByClientAndExecutor[client][sender];
    }

    /// @notice Executor rejects a request → amount + fee above the floor is
    ///         refunded to the client, the floor burns to feeRecipient.
    function rejectRequest(uint256 requestId) external nonReentrant {
        address sender = _msgSender();
        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        ServiceBoardStorage.HireRequest storage req = s.requests[requestId];
        ServiceBoardStorage.Service storage svc = s.services[req.serviceId];

        if (sender != svc.executor) revert NotExecutor();
        if (req.status != ServiceBoardStorage.RequestStatus.PENDING) revert RequestNotPending();

        req.status = ServiceBoardStorage.RequestStatus.REJECTED;
        _decrementPendingCount(s, req.client);
        _removePendingPair(req.client, svc.executor, requestId);
        uint256 refund = s.requestFunds[requestId];
        s.requestFunds[requestId] = 0;

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        uint256 feeHeld = s.requestFeeHeld[requestId];
        s.requestFeeHeld[requestId] = 0;
        uint256 floor_ = fs.feeFloor;
        uint256 burned = feeHeld < floor_ ? feeHeld : floor_;

        // The client first, the fee recipient second, and the second can no
        // longer cancel the first — see FactoryStorage.settleFee.
        _safeTransfer(fs.usdc, req.client, refund + (feeHeld - burned));
        _settleFee(fs, requestId, req.client, FEE_KIND_REQUEST_FORFEIT, burned);

        emit RequestRejected(requestId, sender, req.client);
    }

    // -------- CLIENT: CANCEL --------

    /// @notice Client cancels a request while it is PENDING → amount + fee above
    ///         the floor is refunded, the floor burns to feeRecipient.
    function cancelRequest(uint256 requestId) external nonReentrant {
        address sender = _msgSender();
        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        ServiceBoardStorage.HireRequest storage req = s.requests[requestId];
        ServiceBoardStorage.Service storage svc = s.services[req.serviceId];

        if (sender != req.client) revert NotClient();
        if (req.status != ServiceBoardStorage.RequestStatus.PENDING) revert RequestNotPending();

        req.status = ServiceBoardStorage.RequestStatus.CANCELLED;
        _decrementPendingCount(s, req.client);
        _removePendingPair(req.client, svc.executor, requestId);
        uint256 refund = s.requestFunds[requestId];
        s.requestFunds[requestId] = 0;

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        uint256 feeHeld = s.requestFeeHeld[requestId];
        s.requestFeeHeld[requestId] = 0;
        uint256 floor_ = fs.feeFloor;
        uint256 burned = feeHeld < floor_ ? feeHeld : floor_;

        // The client first, the fee recipient second, and the second can no
        // longer cancel the first — see FactoryStorage.settleFee.
        _safeTransfer(fs.usdc, sender, refund + (feeHeld - burned));
        _settleFee(fs, requestId, sender, FEE_KIND_REQUEST_FORFEIT, burned);

        emit RequestCancelled(requestId, sender);
    }

    // -------- VIEW --------

    function getService(uint256 serviceId) external view returns (ServiceBoardStorage.Service memory) {
        return ServiceBoardStorage.store().services[serviceId];
    }

    function getExecutorServices(address executor) external view returns (uint256[] memory) {
        return ServiceBoardStorage.store().executorServices[executor];
    }

    function getServiceClients(uint256 serviceId) external view returns (address[] memory) {
        return ServiceBoardStorage.store().serviceClients[serviceId];
    }

    function totalServices() external view returns (uint256) {
        return ServiceBoardStorage.store().nextServiceId;
    }

    function getRequest(uint256 requestId) external view returns (ServiceBoardStorage.HireRequest memory) {
        return ServiceBoardStorage.store().requests[requestId];
    }

    function getServiceRequests(uint256 serviceId) external view returns (uint256[] memory) {
        return ServiceBoardStorage.store().serviceRequests[serviceId];
    }

    function getClientRequests(address client) external view returns (uint256[] memory) {
        return ServiceBoardStorage.store().clientRequests[client];
    }

    function totalRequests() external view returns (uint256) {
        return ServiceBoardStorage.store().nextRequestId;
    }

    function getRequestFunds(uint256 requestId) external view returns (uint256) {
        return ServiceBoardStorage.store().requestFunds[requestId];
    }

    /// @notice Fee held in the Diamond against this request. Zeroed on all four
    ///         exits from PENDING. The frontend needs it to say honestly that
    ///         "cancelling returns $X, $1 stays" without recomputing the formula
    ///         itself — live storage holds requests taken at the old rate.
    function getRequestFeeHeld(uint256 requestId) external view returns (uint256) {
        return ServiceBoardStorage.store().requestFeeHeld[requestId];
    }

    /// @notice How many of this client's requests sit in PENDING right now —
    ///         across all executors. requestService gates against this number
    ///         (getMaxPendingRequests), so the frontend has to be able to read it
    ///         instead of learning about the limit from a revert.
    function getPendingRequestCount(address clientAddr) external view returns (uint256) {
        return ServiceBoardStorage.store().pendingRequestCount[clientAddr];
    }

    function getPendingRequestIdsByClientAndExecutor(address clientAddr, address executorAddr) external view returns (uint256[] memory) {
        return ServiceBoardStorage.store().pendingRequestIdsByClientAndExecutor[clientAddr][executorAddr];
    }

    /// @notice All active services together with their IDs
    function getActiveServices() external view returns (
        uint256[] memory ids,
        ServiceBoardStorage.Service[] memory activeServices
    ) {
        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        uint256 total = s.nextServiceId;

        uint256 count = 0;
        for (uint256 i = 0; i < total; i++) {
            if (s.services[i].status == ServiceBoardStorage.ServiceStatus.ACTIVE) count++;
        }

        ids = new uint256[](count);
        activeServices = new ServiceBoardStorage.Service[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < total; i++) {
            if (s.services[i].status == ServiceBoardStorage.ServiceStatus.ACTIVE) {
                ids[idx] = i;
                activeServices[idx] = s.services[i];
                idx++;
            }
        }
    }

    /// @notice Requests for a service that are still PENDING
    function getPendingRequests(uint256 serviceId) external view returns (
        uint256[] memory ids,
        ServiceBoardStorage.HireRequest[] memory pendingReqs
    ) {
        ServiceBoardStorage.Layout storage s = ServiceBoardStorage.store();
        uint256[] storage reqIds = s.serviceRequests[serviceId];
        uint256 count = 0;
        for (uint256 i = 0; i < reqIds.length; i++) {
            if (s.requests[reqIds[i]].status == ServiceBoardStorage.RequestStatus.PENDING) count++;
        }
        ids = new uint256[](count);
        pendingReqs = new ServiceBoardStorage.HireRequest[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < reqIds.length; i++) {
            if (s.requests[reqIds[i]].status == ServiceBoardStorage.RequestStatus.PENDING) {
                ids[idx] = reqIds[i];
                pendingReqs[idx] = s.requests[reqIds[i]];
                idx++;
            }
        }
    }

    // -------- INTERNAL --------

    /// @dev Saturating decrement. Requests created by the earlier revision of
    ///      this facet never incremented the counter (it did not exist yet), so the
    ///      first PENDING→resolved transition on one of those legacy
    ///      requests would read 0 for a client who has never made a request
    ///      under the new code. A plain `--` there is a permanent Panic(0x11)
    ///      on every future accept/reject/cancel/supersede for that client —
    ///      requestFunds stuck in the Diamond with no way out, and even a
    ///      brand-new request from that client can be blocked if a stale
    ///      PENDING sibling is still sitting in the same pair's list. Clamping
    ///      at 0 costs nothing for the steady-state (post-cutover) case, where
    ///      the count is always accurate and never needs clamping.
    function _decrementPendingCount(ServiceBoardStorage.Layout storage s, address clientAddr) internal {
        uint256 c = s.pendingRequestCount[clientAddr];
        if (c != 0) s.pendingRequestCount[clientAddr] = c - 1;
    }

    function _removePendingPair(address clientAddr, address executorAddr, uint256 requestId) internal {
        uint256[] storage list = ServiceBoardStorage.store().pendingRequestIdsByClientAndExecutor[clientAddr][executorAddr];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; i++) {
            if (list[i] == requestId) {
                list[i] = list[len - 1];
                list.pop();
                break;
            }
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ServiceBoard: transferFrom failed");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ServiceBoard: transfer failed");
    }

    /// Hand the protocol its fee, and say out loud which of the two things
    /// happened. The rule — push, and on refusal book the debt — lives once, in
    /// `FactoryStorage.settleFee`; this wrapper exists so that the choice of
    /// event is made once per facet instead of once per call site, and so that
    /// a new fee path cannot pick the wrong one. Twin of the one in
    /// `JobBoardFacet`: a second copy only because the event has to appear in
    /// each facet's own ABI.
    ///
    /// ⚠️ Call this AFTER the person's own money has already been transferred.
    /// The whole point is that their refund does not wait on a third party, and
    /// ordering is the half of that which no helper can enforce.
    function _settleFee(
        FactoryStorage.Layout storage fs,
        uint256 id,
        address payer,
        uint8 kind,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        if (FactoryStorage.settleFee(fs, amount)) {
            emit FeeCollected(id, payer, kind, amount);
        } else {
            emit FeeDeferred(id, payer, kind, amount);
        }
    }
}
