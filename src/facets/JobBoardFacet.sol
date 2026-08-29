// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — JobBoardFacet.sol
// Job marketplace: the client posts a job, the executor applies
// ============================================================
//
// Money flow (fee = max(amount * feeBps / 10_000, feeFloor), see
// FactoryStorage.quote()):
//   mintJob():         amount + fee → held in the Diamond (JobBoardStorage).
//                      The fee is NOT protocol revenue yet — there is no deal.
//   acceptApplicant(): calls FactoryFacet.deployAgreement() through the Diamond;
//                      amount moves from the Diamond → Agreement, and the
//                      held fee moves from the Diamond → feeRecipient
//                      (the deal exists, the fee is earned).
//   cancelJob():       amount and the fee above the floor go back to the client;
//                      the floor ($1) stays with the protocol as the price of a
//                      slot in the feed.
//
// The fee is pushed to the recipient, but a person getting their money out does
// NOT depend on that: on refusal the amount is booked as a debt in
// FactoryStorage.undeliveredFee and pulled later through
// FactoryFacet.withdrawUndeliveredFees(). The rationale and the single
// implementation of the rule live in FactoryStorage.settleFee.
// ============================================================

import "../FactoryFacet.sol"; // for FactoryStorage
import "../DiamondProxy.sol"; // for OwnershipLib

import "./IFactory.sol";

// ---------- RECEIPT NFT INTERFACES ----------

interface IJobReceiptBurn {
    function burnJobReceipt(uint256 jobId) external returns (bool);
}

interface IJobReceiptMint {
    function mintJobReceipt(
        address to,
        uint256 jobId,
        uint256 amount,
        uint256 deadlineDays,
        uint8   region,
        string  calldata title
    ) external returns (uint256);
}

// USDC permit interface (EIP-2612)
interface IJobBoardUSDC {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// per-facet guard removed — the global DiamondGuard from DiamondProxy.sol is used

// ---------- STORAGE ----------

library JobBoardStorage {
    /// @custom:storage-location erc7201:hexseal.jobboard.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.jobboard.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant POSITION = 0x2dfb8cbdd723e055b4c668e1f7986e659e6340635543242a2d9ff47b878af000;

    enum JobStatus { OPEN, ACCEPTED, CANCELLED }

    struct Job {
        address client;
        string title;           // max 100 chars
        string description;     // max 500 chars
        uint256 amount;         // deal amount in USDC (6 decimals)
        uint256 deadlineDays;   // for the Agreement
        string  terms;          // terms of work (on-chain)
        uint8 region;           // PPP region (0=CIS,1=Asia,2=EU,3=US,4=LATAM,5=CA,6=AU)
        JobStatus status;
        uint256 createdAt;
        address chosenExecutor; // address(0) until one is accepted
        address agreement;      // address(0) until it is created
    }

    struct Layout {
        uint256 nextJobId;
        mapping(uint256 => Job) jobs;
        mapping(address => uint256[]) clientJobs;
        mapping(uint256 => address[]) applicants;
        mapping(uint256 => mapping(address => bool)) hasApplied;
        address _deprecated_receiptNFT; // slot kept for storage-layout compatibility
        // Explicit ledger of the USDC held in the Diamond against each job.
        // Zeroed on acceptApplicant / cancelJob.
        mapping(uint256 => uint256) jobFunds;
        // Fee held against each job. It sits here while there is no deal:
        // forwarded to the treasury on acceptApplicant, refunded (except the
        // floor) on cancelJob. Zeroed on both paths.
        mapping(uint256 => uint256) jobFeeHeld;
        // ---- appended 25 August 2026: applicants belong to a job, not to an id ----
        //
        // Generation of the applicant bookkeeping for one job id. It is bumped
        // when the job is CREATED and nowhere else, so a job cannot inherit
        // entries somebody pushed onto its id before that id was handed out.
        //
        // Zero here is NOT "nothing written yet". It is the pre-upgrade
        // generation and it means "this job's applicants live in `applicants`
        // and `hasApplied` above" — which is where every job posted before this
        // upgrade keeps its real ones. Reading zero as "empty" would erase them.
        mapping(uint256 => uint256) applicantGeneration;
        // The same two tables, one namespace per generation. Only generation 1
        // and up live here; generation 0 stays where it has always been.
        mapping(uint256 => mapping(uint256 => address[])) applicantsByGeneration;
        mapping(uint256 => mapping(uint256 => mapping(address => bool))) hasAppliedByGeneration;
    }

    function store() internal pure returns (Layout storage s) {
        bytes32 p = POSITION;
        assembly { s.slot := p }
    }
}

// ---------- FACET ----------

contract JobBoardFacet {

    // -------- EVENTS --------

    event JobPosted(uint256 indexed jobId, address indexed client, uint256 amount, uint8 region, string title, string description, uint256 deadlineDays, string terms);
    event JobApplied(uint256 indexed jobId, address indexed executor);
    event JobWithdrawn(uint256 indexed jobId, address indexed executor);
    event JobAccepted(uint256 indexed jobId, address indexed client, address indexed executor, address agreement);
    event JobCancelled(uint256 indexed jobId, address indexed client, uint256 refundAmount);
    event JobEdited(uint256 indexed jobId, address indexed client, string title, string description, uint256 deadlineDays, string terms, uint8 region);
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
    /// with `FactoryFacet.getUndeliveredFees()`; this event says WHICH job and
    /// WHOSE dollar, which the running total cannot.
    event FeeDeferred(uint256 indexed id, address indexed payer, uint8 indexed kind, uint256 amount);

    uint8 constant FEE_KIND_JOB_DEAL = 0;
    uint8 constant FEE_KIND_JOB_FORFEIT = 1;

    // -------- ERRORS --------

    error TitleInvalid();
    error DescriptionTooLong();
    error ZeroAmount();
    error DeadlineInvalid();
    error InvalidRegion();
    error NotClient();
    error JobNotOpen();
    error NotApplicant();
    error AlreadyApplied();
    error Reentrant();
    error FactoryPaused();
    error SelfApply();
    error JobHasApplicants();
    error JobBoardZeroAddress();
    /// Asked about a job id that was never handed out. Distinct from
    /// `JobNotOpen`, which is about a job that exists and is closed.
    error JobNotFound();

    // -------- REENTRANCY --------

    modifier nonReentrant() {
        if (DiamondGuard.status() == DiamondGuard.ENTERED) revert Reentrant();
        DiamondGuard.setStatus(DiamondGuard.ENTERED);
        _;
        DiamondGuard.setStatus(DiamondGuard.NOT_ENTERED);
    }

    // -------- PAUSE CHECK --------

    modifier whenNotPaused() {
        if (FactoryStorage.store().paused) revert FactoryPaused();
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

    // -------- APPLICANT NAMESPACE --------
    //
    // `JobStatus.OPEN` is zero, so before this upgrade every id that had never
    // been written read back as an open job and `applyForJob` accepted entries
    // on ids no client had posted yet. `applyForJob` now refuses those ids, but
    // whatever was pushed onto them BEFORE the upgrade is still in storage, and
    // storage is what the next client to be handed that id would have
    // inherited: a job born with applicants it never invited, and — because
    // `editJob` refuses to touch a job that has any — one that could never be
    // corrected.
    //
    // Clearing that list at creation is not affordable: `delete
    // s.applicants[jobId]` costs one store per entry, and the number of entries
    // was chosen by whoever left them, so a client could be handed an id that
    // costs more gas to post on than a block allows. Bumping a generation
    // instead is a single store, whatever was left behind, and leaves the old
    // entries where they are — unreachable rather than deleted.

    /// The applicant list of `jobId`, in the generation that job owns.
    ///
    /// Returns the storage slot itself, not a copy: `applyForJob` pushes
    /// through it and `withdrawApplication` pops through it. `view` describes
    /// only what happens HERE — reading one word to choose a slot; whether the
    /// caller then writes through the pointer is the caller's mutability.
    function _applicantsOf(JobBoardStorage.Layout storage s, uint256 jobId)
        internal
        view
        returns (address[] storage)
    {
        uint256 generation = s.applicantGeneration[jobId];
        if (generation == 0) return s.applicants[jobId];
        return s.applicantsByGeneration[jobId][generation];
    }

    /// The `hasApplied` table of `jobId`, in the generation that job owns.
    /// Same split, and it matters as much as the list: a stale `true` here
    /// would let `acceptApplicant` hire somebody the client never saw on the
    /// board, and would answer `AlreadyApplied` to an executor applying for the
    /// first time.
    function _hasAppliedOf(JobBoardStorage.Layout storage s, uint256 jobId)
        internal
        view
        returns (mapping(address => bool) storage)
    {
        uint256 generation = s.applicantGeneration[jobId];
        if (generation == 0) return s.hasApplied[jobId];
        return s.hasAppliedByGeneration[jobId][generation];
    }

    /// Hands the freshly created `jobId` an applicant namespace of its own.
    /// Called by both writers of `nextJobId` and by nothing else — a job that
    /// skipped this would read the pre-upgrade tables and inherit them.
    function _beginApplicantGeneration(JobBoardStorage.Layout storage s, uint256 jobId) internal {
        s.applicantGeneration[jobId] += 1;
    }

    // -------- WRITE --------

    /// @notice Client posts a job — gasless via off-chain USDC permit
    function mintJobWithPermit(
        address client,
        string memory title,
        string memory description,
        uint256 amount,
        uint256 deadlineDays,
        string  memory terms,
        uint8 region,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused returns (uint256 jobId) {
        // --- Validation ---
        uint256 titleLen = bytes(title).length;
        if (titleLen == 0 || titleLen > 100) revert TitleInvalid();
        if (bytes(description).length > 500) revert DescriptionTooLong();
        if (amount == 0) revert ZeroAmount();
        if (deadlineDays == 0 || deadlineDays > 365) revert DeadlineInvalid();
        if (region > 6) revert InvalidRegion();

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        uint256 fee = FactoryStorage.quote(fs, amount);

        uint256 total = amount + fee;

        IJobBoardUSDC(fs.usdc).permit(client, address(this), total, permitDeadline, v, r, s);

        // --- Effects ---
        JobBoardStorage.Layout storage jbs = JobBoardStorage.store();
        jobId = jbs.nextJobId++;
        _beginApplicantGeneration(jbs, jobId);

        jbs.jobs[jobId] = JobBoardStorage.Job({
            client:         client,
            title:          title,
            description:    description,
            amount:         amount,
            deadlineDays:   deadlineDays,
            terms:          terms,
            region:         region,
            status:         JobBoardStorage.JobStatus.OPEN,
            createdAt:      block.timestamp,
            chosenExecutor: address(0),
            agreement:      address(0)
        });
        jbs.clientJobs[client].push(jobId);

        // --- Transfers ---
        _safeTransferFrom(fs.usdc, client, address(this), total);
        jbs.jobFunds[jobId]   = amount;
        jbs.jobFeeHeld[jobId] = fee;

        // --- Auto-mint job receipt NFT (non-blocking) ---
        try IJobReceiptMint(address(this)).mintJobReceipt(client, jobId, amount, deadlineDays, region, title) {} catch {}

        emit JobPosted(jobId, client, amount, region, title, description, deadlineDays, terms);
    }

    /// @notice Client posts a job — gasless-compatible (ERC-2771).
    /// @dev On the gasless path the relayer calls USDC.permit() separately before the ForwardRequest.
    ///      The direct path requires approve(diamond, fee + amount) before the call.
    function mintJob(
        string memory title,
        string memory description,
        uint256 amount,
        uint256 deadlineDays,
        string  memory terms,
        uint8 region
    ) external nonReentrant whenNotPaused returns (uint256 jobId) {
        address client = _msgSender();

        // --- Validation ---
        uint256 titleLen = bytes(title).length;
        if (titleLen == 0 || titleLen > 100) revert TitleInvalid();
        if (bytes(description).length > 500) revert DescriptionTooLong();
        if (amount == 0) revert ZeroAmount();
        if (deadlineDays == 0 || deadlineDays > 365) revert DeadlineInvalid();
        if (region > 6) revert InvalidRegion();

        FactoryStorage.Layout storage fs = FactoryStorage.store();
        uint256 fee = FactoryStorage.quote(fs, amount);

        // --- Effects ---
        JobBoardStorage.Layout storage s = JobBoardStorage.store();
        jobId = s.nextJobId++;
        _beginApplicantGeneration(s, jobId);

        s.jobs[jobId] = JobBoardStorage.Job({
            client:         client,
            title:          title,
            description:    description,
            amount:         amount,
            deadlineDays:   deadlineDays,
            terms:          terms,
            region:         region,
            status:         JobBoardStorage.JobStatus.OPEN,
            createdAt:      block.timestamp,
            chosenExecutor: address(0),
            agreement:      address(0)
        });
        s.clientJobs[client].push(jobId);

        // --- Transfers ---
        _safeTransferFrom(fs.usdc, client, address(this), amount + fee);
        s.jobFunds[jobId]   = amount;
        s.jobFeeHeld[jobId] = fee;

        // --- Auto-mint job receipt NFT (non-blocking) ---
        try IJobReceiptMint(address(this)).mintJobReceipt(client, jobId, amount, deadlineDays, region, title) {} catch {}

        emit JobPosted(jobId, client, amount, region, title, description, deadlineDays, terms);
    }

    /// @notice Executor withdraws an application (while the job is OPEN, gasless-compatible)
    function withdrawApplication(uint256 jobId) external {
        address sender = _msgSender();
        JobBoardStorage.Layout storage s = JobBoardStorage.store();
        JobBoardStorage.Job storage job = s.jobs[jobId];

        if (job.status != JobBoardStorage.JobStatus.OPEN) revert JobNotOpen();

        mapping(address => bool) storage applied = _hasAppliedOf(s, jobId);
        if (!applied[sender]) revert NotApplicant();

        applied[sender] = false;

        // Swap-and-pop, so the array is not shifted to keep order
        address[] storage appl = _applicantsOf(s, jobId);
        uint256 len = appl.length;
        for (uint256 i = 0; i < len; i++) {
            if (appl[i] == sender) {
                appl[i] = appl[len - 1];
                appl.pop();
                break;
            }
        }

        emit JobWithdrawn(jobId, sender);
    }

    /// @notice Executor applies for a job (gasless-compatible through ERC-2771)
    function applyForJob(uint256 jobId) external {
        address sender = _msgSender();
        JobBoardStorage.Layout storage s = JobBoardStorage.store();

        // A job nobody posted is not an open job. The status check below cannot
        // say so: `JobStatus.OPEN` is zero, so an id that has never been written
        // reads back as open, and an entry on it lands in the storage of a job
        // that does not exist yet. The counter can say so — `nextJobId` moves
        // only in the two minters, one step per job created, and never goes
        // back, so `jobId < nextJobId` means exactly "this id has been handed
        // out". It is a statement about existence, not about status: a
        // CANCELLED or ACCEPTED job is past this line and is turned away below,
        // by name, as before.
        if (jobId >= s.nextJobId) revert JobNotFound();

        JobBoardStorage.Job storage job = s.jobs[jobId];

        if (job.status != JobBoardStorage.JobStatus.OPEN) revert JobNotOpen();
        if (sender == job.client) revert SelfApply();

        mapping(address => bool) storage applied = _hasAppliedOf(s, jobId);
        if (applied[sender]) revert AlreadyApplied();

        applied[sender] = true;
        _applicantsOf(s, jobId).push(sender);

        emit JobApplied(jobId, sender);
    }

    /// @notice Client accepts an executor → the Factory deploys the Agreement (gasless-compatible)
    function acceptApplicant(
        uint256 jobId,
        address executor
    ) external nonReentrant whenNotPaused returns (address agreementAddr) {
        address sender = _msgSender();
        JobBoardStorage.Layout storage s = JobBoardStorage.store();
        JobBoardStorage.Job storage job = s.jobs[jobId];

        if (sender != job.client) revert NotClient();
        if (job.status != JobBoardStorage.JobStatus.OPEN) revert JobNotOpen();
        if (!_hasAppliedOf(s, jobId)[executor]) revert NotApplicant();

        // --- Effects ---
        job.status = JobBoardStorage.JobStatus.ACCEPTED;
        job.chosenExecutor = executor;

        // --- Deploy through the Factory ---
        (bool ok, bytes memory ret) = address(this).call(
            abi.encodeWithSelector(
                IFactory.deployAgreement.selector,
                job.client,
                executor,
                address(0),
                job.amount,
                job.deadlineDays,
                job.terms,
                job.region
            )
        );
        require(ok, "JobBoard: deploy failed");
        agreementAddr = abi.decode(ret, (address));
        if (agreementAddr == address(0)) revert JobBoardZeroAddress();

        job.agreement = agreementAddr;

        // --- Transfer amount out of the Diamond → Agreement ---
        FactoryStorage.Layout storage fs = FactoryStorage.store();
        uint256 held = s.jobFunds[jobId];
        require(held == job.amount, "JobBoard: ledger mismatch");
        s.jobFunds[jobId] = 0;
        _safeTransfer(fs.usdc, agreementAddr, held);

        // The deal exists — the fee is earned and goes to the treasury. If it
        // does not arrive it becomes a debt to the protocol, not a reason to undo
        // the hire: the client's money is already in the Agreement, and a revert
        // on this line would put it back in the diamond, where a cancel would hit
        // that same transfer all over again.
        uint256 feeHeld = s.jobFeeHeld[jobId];
        s.jobFeeHeld[jobId] = 0;
        _settleFee(fs, jobId, job.client, FEE_KIND_JOB_DEAL, feeHeld);

        // --- Activate the Agreement ---
        (bool funded, ) = agreementAddr.call(abi.encodeWithSignature("fundFromFactory()"));
        require(funded, "JobBoard: fund failed");

        // The posting receipt is stale — the money is in the Agreement now, and
        // that has its own NFT receipt for both sides. The burn is non-blocking,
        // as in cancelJob.
        try IJobReceiptBurn(address(this)).burnJobReceipt(jobId) {} catch {}

        emit JobAccepted(jobId, job.client, executor, agreementAddr);
    }

    /// @notice Client cancels a job — gasless-compatible.
    /// @dev amount and the fee above the floor ($1) go back to the client; the
    ///      floor stays with the protocol as the price of a slot in the feed.
    function cancelJob(uint256 jobId) external nonReentrant {
        address sender = _msgSender();
        JobBoardStorage.Layout storage s = JobBoardStorage.store();
        JobBoardStorage.Job storage job = s.jobs[jobId];

        if (sender != job.client) revert NotClient();
        if (job.status != JobBoardStorage.JobStatus.OPEN) revert JobNotOpen();

        // --- Effects ---
        job.status = JobBoardStorage.JobStatus.CANCELLED;
        uint256 refund = s.jobFunds[jobId];
        require(refund > 0, "JobBoard: no funds recorded");
        s.jobFunds[jobId] = 0;

        // --- Interaction ---
        FactoryStorage.Layout storage fs = FactoryStorage.store();

        // There was no deal — the percentage is refunded, the floor stays with the protocol.
        uint256 feeHeld = s.jobFeeHeld[jobId];
        s.jobFeeHeld[jobId] = 0;
        uint256 floor_ = fs.feeFloor;
        uint256 burned = feeHeld < floor_ ? feeHeld : floor_;

        // The client first, the fee recipient second, and the second can no
        // longer cancel the first: on live job #3 that was 36.19 USDC riding on
        // the success of a 1.00 USDC transfer to an unrelated address.
        uint256 returned = refund + (feeHeld - burned);
        _safeTransfer(fs.usdc, job.client, returned);
        _settleFee(fs, jobId, job.client, FEE_KIND_JOB_FORFEIT, burned);

        // Burn receipt NFT — non-blocking so a failure doesn't block the refund
        try IJobReceiptBurn(address(this)).burnJobReceipt(jobId) {} catch {}

        // refundAmount = what actually came back to the client (amount + the
        // above-the-floor part of the fee), not the job amount alone — that is
        // how the frontend reads it.
        emit JobCancelled(jobId, job.client, returned);
    }

    /// @notice Client edits a job while it is OPEN and has NO applicants (gasless-compatible).
    /// @dev amount is immutable — the money is already locked in the Diamond at the old figure.
    ///      A different amount means cancelling the job and posting a new one.
    ///      Editing is forbidden after the first application — changing the terms
    ///      under executors who have already applied would not be fair to them.
    function editJob(
        uint256 jobId,
        string memory title,
        string memory description,
        uint256 deadlineDays,
        string  memory terms,
        uint8 region
    ) external whenNotPaused {
        address sender = _msgSender();
        JobBoardStorage.Layout storage s = JobBoardStorage.store();
        JobBoardStorage.Job storage job = s.jobs[jobId];

        if (sender != job.client) revert NotClient();
        if (job.status != JobBoardStorage.JobStatus.OPEN) revert JobNotOpen();
        if (_applicantsOf(s, jobId).length > 0) revert JobHasApplicants();

        // --- Validation (the same as on mint) ---
        uint256 titleLen = bytes(title).length;
        if (titleLen == 0 || titleLen > 100) revert TitleInvalid();
        if (bytes(description).length > 500) revert DescriptionTooLong();
        if (deadlineDays == 0 || deadlineDays > 365) revert DeadlineInvalid();
        if (region > 6) revert InvalidRegion();

        // --- Effects ---
        job.title        = title;
        job.description  = description;
        job.deadlineDays = deadlineDays;
        job.terms        = terms;
        job.region       = region;

        emit JobEdited(jobId, sender, title, description, deadlineDays, terms, region);
    }

    // -------- VIEW --------

    function getJob(uint256 jobId) external view returns (JobBoardStorage.Job memory) {
        return JobBoardStorage.store().jobs[jobId];
    }

    function getClientJobs(address client) external view returns (uint256[] memory) {
        return JobBoardStorage.store().clientJobs[client];
    }

    function getApplicants(uint256 jobId) external view returns (address[] memory) {
        return _applicantsOf(JobBoardStorage.store(), jobId);
    }

    function totalJobs() external view returns (uint256) {
        return JobBoardStorage.store().nextJobId;
    }

    /// @notice Fee held in the Diamond against this job. Zeroed both on
    ///         acceptApplicant and on cancelJob. The frontend needs it to say
    ///         honestly that "cancelling returns $X, $1 stays" without recomputing
    ///         the formula itself — live storage holds jobs taken at the old rate,
    ///         and a client-side recomputation would disagree with them.
    function getJobFeeHeld(uint256 jobId) external view returns (uint256) {
        return JobBoardStorage.store().jobFeeHeld[jobId];
    }

    /// @notice Returns every OPEN job together with its ID
    function getOpenJobs() external view returns (uint256[] memory ids, JobBoardStorage.Job[] memory openJobs) {
        JobBoardStorage.Layout storage s = JobBoardStorage.store();
        uint256 total = s.nextJobId;

        uint256 count = 0;
        for (uint256 i = 0; i < total; i++) {
            if (s.jobs[i].status == JobBoardStorage.JobStatus.OPEN) count++;
        }

        ids = new uint256[](count);
        openJobs = new JobBoardStorage.Job[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < total; i++) {
            if (s.jobs[i].status == JobBoardStorage.JobStatus.OPEN) {
                ids[idx] = i;
                openJobs[idx] = s.jobs[i];
                idx++;
            }
        }
    }

    // -------- INTERNAL --------

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "JobBoard: transferFrom failed");
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "JobBoard: transfer failed");
    }

    /// Hand the protocol its fee, and say out loud which of the two things
    /// happened. The rule — push, and on refusal book the debt — lives once, in
    /// `FactoryStorage.settleFee`; this wrapper exists so that the choice of
    /// event is made once per facet instead of once per call site, and so that
    /// a new fee path cannot pick the wrong one.
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
