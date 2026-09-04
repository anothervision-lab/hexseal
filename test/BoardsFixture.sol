// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/JobReceiptFacet.sol";

// ---------- MOCK USDC ----------

contract MockUSDCB {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ---- A receiver that will not take the money ----
    //
    // Real USDC keeps a blacklist and its `transfer` REVERTS when either side
    // of it is on the list. Without something that refuses, the scene this
    // whole piece of work is about — "the fee recipient says no, does the
    // person still get their money" — cannot be played at all, and every test
    // below it would be measuring the happy path twice.
    //
    // Two flavours, because a token can say no in two ways and the code under
    // test has to survive both: `blacklisted` reverts (what USDC does), and
    // `refusesSilently` returns false without reverting (what a token with the
    // older, non-reverting ERC-20 habit does). A settlement that only handles
    // the first would book no debt at all for the second — it would read the
    // `false` as success and the dollar would vanish from the ledger.
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public refusesSilently;

    function setBlacklisted(address who, bool on) external { blacklisted[who] = on; }
    function setRefusesSilently(address who, bool on) external { refusesSilently[who] = on; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!blacklisted[to] && !blacklisted[msg.sender], "blacklisted");
        if (refusesSilently[to]) return false;
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!blacklisted[to] && !blacklisted[from], "blacklisted");
        if (refusesSilently[to]) return false;
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // Test-only stub: a real EIP-2612 permit() verifies (v, r, s) against a
    // signed digest and checks `deadline`. No test in this suite exercises
    // signature validity itself (that's real USDC's job on testnet, not this
    // facet's) — only the gasless call path that relies on the allowance
    // being set afterward. This mock skips verification and sets it directly.
    function permit(
        address tokenOwner,
        address spender,
        uint256 value,
        uint256 /*deadline*/,
        uint8 /*v*/,
        bytes32 /*r*/,
        bytes32 /*s*/
    ) external {
        allowance[tokenOwner][spender] = value;
    }
}

// ---------- FIXTURE ----------

abstract contract BoardsFixture is Test {
    DiamondProxy diamond;
    MockUSDCB usdc;

    address owner;
    address client;
    address executor;
    address feeRecipient;

    uint8 constant REGION = 0; // CIS — the region enum still exists on Job/Service, but no longer sets the fee
    // A leftover of the retired regional fee model. mintService and
    // mintServiceWithPermit now take exactly fs.feeFloor ($1) — this approve
    // ceiling ($2) covers that with room to spare, so the constant itself is
    // worth leaving alone; calling it "ServiceBoard fee (fs.regionFee)" would
    // be wrong, though: regionFee is a dead field (see FactoryStorage.Layout)
    // and the payment differs from $2.
    uint256 constant FEE = 2_000_000; // $2 USDC — approve ceiling; the real fee is lower (fs.feeFloor)
    uint256 constant AMOUNT = 100_000_000; // $100 USDC
    // JobBoard now prices through quote(): max(AMOUNT * 500 / 10_000, 1_000_000).
    uint256 constant JOB_FEE = 5_000_000;   // 5% of AMOUNT
    uint256 constant JOB_FLOOR = 1_000_000; // fs.feeFloor — the floor that survives cancelJob
    uint256 constant DEADLINE = 7;
    string constant TERMS = "Standard work terms";

    /// Base slots of the fee-model fields inside FactoryStorage.Layout.
    /// Read off by the packing rules: usdc(0), feeRecipient(1), regionFee(2),
    /// trustedForwarder(3), diamond+paused(4 — the bool packed into the tail of
    /// the slot), protocolArbiter(5), arbitrationThreshold(6),
    /// agreementDeployer(7), feeBps(8), feeFloor(9), maxPendingRequests(10),
    /// undeliveredFee(11), newDealsPausedUntil(12 — appended 3 September 2026).
    /// The offsets are not taken on trust — _unconfigureFeeModel() first asserts
    /// that the values initFactory seeded really are sitting at them, and only
    /// then zeroes them.
    uint256 constant SLOT_FEE_BPS              = 8;
    uint256 constant SLOT_FEE_FLOOR            = 9;
    uint256 constant SLOT_MAX_PENDING_REQUESTS = 10;

    /// Mirror of the FEE_KIND_* constants declared inside JobBoardFacet /
    /// ServiceBoardFacet. Those are plain (non-public) constants — matching the
    /// facets' own style (see MAX_PENDING_PER_PAIR) and keeping the diamond's
    /// mounted selector set untouched — so they aren't reachable as
    /// `JobBoardFacet.FEE_KIND_JOB_DEAL` from outside the contract. Mirrored
    /// here once so tests reference a name, not a bare number.
    /// Same story for FactoryFacet.FEE_KIND_DIRECT_DEAL — mirrored here too.
    uint8 constant FEE_KIND_JOB_DEAL        = 0;
    uint8 constant FEE_KIND_JOB_FORFEIT     = 1;
    uint8 constant FEE_KIND_SERVICE_LISTING = 2;
    uint8 constant FEE_KIND_REQUEST_DEAL    = 3;
    uint8 constant FEE_KIND_REQUEST_FORFEIT = 4;
    uint8 constant FEE_KIND_DIRECT_DEAL     = 5;

    /// `virtual` since 25 August 2026: test/BoardFeeDeliveryUpgrade.t.sol needs
    /// the same actors and the same mock token but a diamond in the LIVE shape
    /// rather than this fixture's, because a cut that replaces FactoryFacet has
    /// to be rehearsed against the selector set the chain really routes.
    function setUp() public virtual {
        owner = address(this);
        client = address(0x1);
        executor = address(0x2);
        feeRecipient = address(0x4);

        usdc = new MockUSDCB();
        usdc.mint(client, 1_000_000_000);   // $1000
        usdc.mint(executor, 100_000_000);   // $100

        (diamond, ) = _deployBoardsDiamond();
    }

    /// Deploys the diamond in exactly the configuration the board tests expect.
    /// Pulled out of setUp because the upgrade-window tests need a SECOND,
    /// independent diamond — same set of facets, but with no seeded fee model
    /// (see _deployUnconfiguredDiamond).
    ///
    /// FactoryFacet is mounted WITHOUT initFeeModel: on the live diamond that
    /// selector does not exist yet, and it is added by the very Add batch these
    /// tests reproduce. Mounting it in advance is impossible — diamondCut
    /// reverts "Diamond: selector exists" on a repeated Add.
    function _deployBoardsDiamond() internal returns (DiamondProxy d, address factoryImpl) {
        // --- Deploy facets ---
        RegistryFacet registryFacet = new RegistryFacet();
        FactoryFacet factoryFacet = new FactoryFacet();
        DiamondCutFacet diamondCutFacet = new DiamondCutFacet();
        DiamondLoupeFacet diamondLoupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        JobBoardFacet jobBoardFacet = new JobBoardFacet();
        ServiceBoardFacet serviceBoardFacet = new ServiceBoardFacet();
        JobReceiptFacet jobReceiptFacet = new JobReceiptFacet();

        // --- Registry selectors ---
        bytes4[] memory regSels = new bytes4[](12);
        regSels[0] = RegistryFacet.initRegistry.selector;
        regSels[1] = RegistryFacet.register.selector;
        regSels[2] = RegistryFacet.updateStatus.selector;
        regSels[3] = RegistryFacet.setAuthorizedFactory.selector;
        regSels[4] = RegistryFacet.hasActivePair.selector;
        regSels[5] = RegistryFacet.getActivePair.selector;
        regSels[6] = RegistryFacet.getRecord.selector;
        regSels[7] = RegistryFacet.getByClient.selector;
        regSels[8] = RegistryFacet.getByExecutor.selector;
        regSels[9] = RegistryFacet.getActive.selector;
        regSels[10] = RegistryFacet.totalAgreements.selector;
        regSels[11] = RegistryFacet.authorizedFactory.selector;

        // --- Factory selectors ---
        bytes4[] memory facSels = new bytes4[](27);
        facSels[0] = FactoryFacet.initFactory.selector;
        facSels[1] = FactoryFacet.deployAgreement.selector;
        facSels[2] = FactoryFacet.setRegionFee.selector;
        facSels[3] = FactoryFacet.setFeeRecipient.selector;
        facSels[4] = FactoryFacet.setTrustedForwarder.selector;
        facSels[5] = bytes4(0x16c38b3c);
        facSels[6] = FactoryFacet.getRegionFee.selector;
        facSels[7] = FactoryFacet.getAllFees.selector;
        facSels[8] = FactoryFacet.getFeeRecipient.selector;
        facSels[9] = FactoryFacet.getTrustedForwarder.selector;
        facSels[10] = bytes4(0xb187bd26);
        facSels[11] = FactoryFacet.getUsdc.selector;
        facSels[12] = bytes4(0x220f72fc);
        facSels[13] = FactoryFacet.setFeeBps.selector;
        facSels[14] = FactoryFacet.setFeeFloor.selector;
        facSels[15] = FactoryFacet.setMaxPendingRequests.selector;
        facSels[16] = FactoryFacet.quoteFee.selector;
        facSels[17] = FactoryFacet.getMaxPendingRequests.selector;
        facSels[18] = FactoryFacet.getFeeBps.selector;
        facSels[19] = FactoryFacet.getFeeFloor.selector;
        facSels[20] = FactoryFacet.deployAndFund.selector;
        // The fee the feeRecipient did not accept: the debt and the way to claim it.
        facSels[21] = FactoryFacet.getUndeliveredFees.selector;
        facSels[22] = FactoryFacet.withdrawUndeliveredFees.selector;
        // The emergency brake (decision 17), added 3 September 2026. Mounted
        // here rather than in a cut of its own because every board test that
        // touches a money door now has to be able to ask whether the door is
        // braked — and because a selector this fixture does not mount is a
        // selector no board test can prove is missing.
        facSels[23] = FactoryFacet.pauseNewDeals.selector;
        facSels[24] = FactoryFacet.resumeNewDeals.selector;
        facSels[25] = FactoryFacet.newDealsPausedUntil.selector;
        // A public constant's getter has no `.selector` on the contract type —
        // Solidity only exposes that for functions — so it is spelled out.
        facSels[26] = bytes4(keccak256("NEW_DEALS_PAUSE_DURATION()"));
        // initFeeModel is deliberately NOT mounted — the atomic-seeding test adds
        // it with a diamondCut of its own, and a repeated Add reverts.

        // --- JobBoardFacet selectors ---
        bytes4[] memory jobSels = new bytes4[](13);
        jobSels[0]  = JobBoardFacet.mintJob.selector;
        jobSels[1]  = JobBoardFacet.applyForJob.selector;
        jobSels[2]  = JobBoardFacet.acceptApplicant.selector;
        jobSels[3]  = JobBoardFacet.cancelJob.selector;
        jobSels[4]  = JobBoardFacet.getJob.selector;
        jobSels[5]  = JobBoardFacet.getClientJobs.selector;
        jobSels[6]  = JobBoardFacet.getApplicants.selector;
        jobSels[7]  = JobBoardFacet.withdrawApplication.selector;
        jobSels[8]  = JobBoardFacet.editJob.selector;
        jobSels[9]  = JobBoardFacet.totalJobs.selector;
        jobSels[10] = JobBoardFacet.getOpenJobs.selector;
        jobSels[11] = JobBoardFacet.getJobFeeHeld.selector;
        jobSels[12] = JobBoardFacet.mintJobWithPermit.selector;

        // --- ServiceBoardFacet selectors ---
        bytes4[] memory svcSels = new bytes4[](25);
        svcSels[0]  = ServiceBoardFacet.mintService.selector;
        svcSels[1]  = ServiceBoardFacet.requestService.selector;
        svcSels[2]  = ServiceBoardFacet.acceptRequest.selector;
        svcSels[3]  = ServiceBoardFacet.rejectRequest.selector;
        svcSels[4]  = ServiceBoardFacet.cancelRequest.selector;
        svcSels[5]  = ServiceBoardFacet.removeService.selector;
        svcSels[6]  = ServiceBoardFacet.pauseService.selector;
        svcSels[7]  = ServiceBoardFacet.unpauseService.selector;
        svcSels[8]  = ServiceBoardFacet.getService.selector;
        svcSels[9]  = ServiceBoardFacet.getExecutorServices.selector;
        svcSels[10] = ServiceBoardFacet.getServiceClients.selector;
        svcSels[11] = ServiceBoardFacet.getRequest.selector;
        svcSels[12] = ServiceBoardFacet.getServiceRequests.selector;
        svcSels[13] = ServiceBoardFacet.getClientRequests.selector;
        svcSels[14] = ServiceBoardFacet.totalServices.selector;
        svcSels[15] = ServiceBoardFacet.editService.selector;
        svcSels[16] = ServiceBoardFacet.totalRequests.selector;
        svcSels[17] = ServiceBoardFacet.getRequestFunds.selector;
        svcSels[18] = ServiceBoardFacet.getActiveServices.selector;
        svcSels[19] = ServiceBoardFacet.getPendingRequests.selector;
        svcSels[20] = ServiceBoardFacet.getPendingRequestIdsByClientAndExecutor.selector;
        svcSels[21] = ServiceBoardFacet.getRequestFeeHeld.selector;
        svcSels[22] = ServiceBoardFacet.getPendingRequestCount.selector;
        svcSels[23] = ServiceBoardFacet.mintServiceWithPermit.selector;
        svcSels[24] = ServiceBoardFacet.requestServiceWithPermit.selector;

        // --- Infrastructure selectors ---
        bytes4[] memory cutSels = new bytes4[](1);
        cutSels[0] = DiamondCutFacet.diamondCut.selector;

        bytes4[] memory loupeSels = new bytes4[](5);
        loupeSels[0] = DiamondLoupeFacet.facets.selector;
        loupeSels[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        loupeSels[2] = DiamondLoupeFacet.facetAddresses.selector;
        loupeSels[3] = DiamondLoupeFacet.facetAddress.selector;
        loupeSels[4] = DiamondLoupeFacet.supportsInterface.selector;

        bytes4[] memory ownSels = new bytes4[](4);
        ownSels[0] = OwnershipFacet.transferOwnership.selector;
        ownSels[1] = OwnershipFacet.owner.selector;
        ownSels[2] = OwnershipFacet.acceptOwnership.selector;
        ownSels[3] = OwnershipFacet.pendingOwner.selector;

        // --- JobReceiptFacet selectors (supportsInterface excluded — already in DiamondLoupe) ---
        bytes4[] memory receiptSels = new bytes4[](21);
        receiptSels[0]  = JobReceiptFacet.name.selector;
        receiptSels[1]  = JobReceiptFacet.symbol.selector;
        receiptSels[2]  = JobReceiptFacet.balanceOf.selector;
        receiptSels[3]  = JobReceiptFacet.ownerOf.selector;
        receiptSels[4]  = JobReceiptFacet.tokenURI.selector;
        receiptSels[5]  = bytes4(keccak256("transferFrom(address,address,uint256)"));
        receiptSels[6]  = bytes4(keccak256("safeTransferFrom(address,address,uint256)"));
        receiptSels[7]  = bytes4(keccak256("safeTransferFrom(address,address,uint256,bytes)"));
        receiptSels[8]  = bytes4(keccak256("approve(address,uint256)"));
        receiptSels[9]  = bytes4(keccak256("setApprovalForAll(address,bool)"));
        receiptSels[10] = JobReceiptFacet.getApproved.selector;
        receiptSels[11] = JobReceiptFacet.isApprovedForAll.selector;
        receiptSels[12] = JobReceiptFacet.setSvgRenderer.selector;
        receiptSels[13] = JobReceiptFacet.getSvgRenderer.selector;
        receiptSels[14] = JobReceiptFacet.mintJobReceipt.selector;
        receiptSels[15] = JobReceiptFacet.getJobReceiptData.selector;
        receiptSels[16] = JobReceiptFacet.isJobReceiptToken.selector;
        receiptSels[17] = JobReceiptFacet.getReceiptTotalSupply.selector;
        receiptSels[18] = JobReceiptFacet.burnJobReceipt.selector;
        receiptSels[19] = JobReceiptFacet.isJobReceiptBurned.selector;
        receiptSels[20] = JobReceiptFacet.getTokenIdByJobId.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](8);
        cut[0] = IDiamondCut.FacetCut(address(registryFacet),    IDiamondCut.FacetCutAction.Add, regSels);
        cut[1] = IDiamondCut.FacetCut(address(factoryFacet),     IDiamondCut.FacetCutAction.Add, facSels);
        cut[2] = IDiamondCut.FacetCut(address(diamondCutFacet),  IDiamondCut.FacetCutAction.Add, cutSels);
        cut[3] = IDiamondCut.FacetCut(address(diamondLoupeFacet),IDiamondCut.FacetCutAction.Add, loupeSels);
        cut[4] = IDiamondCut.FacetCut(address(ownershipFacet),   IDiamondCut.FacetCutAction.Add, ownSels);
        cut[5] = IDiamondCut.FacetCut(address(jobBoardFacet),    IDiamondCut.FacetCutAction.Add, jobSels);
        cut[6] = IDiamondCut.FacetCut(address(serviceBoardFacet),IDiamondCut.FacetCutAction.Add, svcSels);
        cut[7] = IDiamondCut.FacetCut(address(jobReceiptFacet),  IDiamondCut.FacetCutAction.Add, receiptSels);

        d = new DiamondProxy(owner, cut, address(0), "");
        factoryImpl = address(factoryFacet);

        // Init Registry (authorizedFactory = Diamond itself)
        RegistryFacet(address(d)).initRegistry(address(d));

        // Init Factory
        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(d), address(agreementImpl));
        FactoryFacet(address(d)).initFactory(
            address(usdc),
            feeRecipient,
            address(0xDEAD),
            address(d),
            address(agDeployer)
        );
    }

    /// The diamond in the state of the live 0x760F… RIGHT AFTER the diamondCut
    /// and BEFORE the configuring transaction: new facets, usdc/feeRecipient/
    /// deployer in place, but feeBps/feeFloor/maxPendingRequests at zero,
    /// because those fields never existed in the live storage.
    ///
    /// initFactory() on a fresh facet seeds them itself (for the sake of a
    /// from-scratch deployment), so here they are zeroed back out through
    /// vm.store — the very same device by which
    /// testLegacyPendingRequestDoesNotUnderflowOnResolve reproduces the state
    /// that is lying on chain.
    function _deployUnconfiguredDiamond() internal returns (DiamondProxy d, address factoryImpl) {
        (d, factoryImpl) = _deployBoardsDiamond();
        _unconfigureFeeModel(address(d));
    }

    function _unconfigureFeeModel(address d) internal {
        bytes32 base = FactoryStorage.FACTORY_STORAGE_POSITION;
        bytes32 bpsSlot        = bytes32(uint256(base) + SLOT_FEE_BPS);
        bytes32 floorSlot      = bytes32(uint256(base) + SLOT_FEE_FLOOR);
        bytes32 maxPendingSlot = bytes32(uint256(base) + SLOT_MAX_PENDING_REQUESTS);

        // The offsets are not taken on trust: initFactory has just written
        // 500 / $1 / 5 here. If the Layout drifts, the test fails right here
        // instead of quietly zeroing somebody else's field and going on to
        // "check" something entirely different.
        assertEq(uint256(vm.load(d, bpsSlot)), 500, "feeBps slot offset drifted");
        assertEq(uint256(vm.load(d, floorSlot)), 1_000_000, "feeFloor slot offset drifted");
        assertEq(uint256(vm.load(d, maxPendingSlot)), 5, "maxPendingRequests slot offset drifted");

        vm.store(d, bpsSlot, bytes32(uint256(0)));
        vm.store(d, floorSlot, bytes32(uint256(0)));
        vm.store(d, maxPendingSlot, bytes32(uint256(0)));
    }

    // ============================================================
    //  FEE LEDGER — structural completeness helpers
    // ============================================================
    //
    // `vm.expectEmit` only proves "at least one matching event was emitted" —
    // it stays green even if a SECOND, undeclared transfer to feeRecipient
    // rides along in the same call. The ledger-completeness property this
    // task is actually about ("every USDC that reaches feeRecipient is
    // announced by a FeeCollected") is a different, stronger claim, and has
    // to be checked as a balance identity, not as a log match. Wrapping every
    // mutating call that can pay feeRecipient through `_assertLedgerBalanced`
    // makes that check structural — it fires on every call site, including
    // ones added after this comment was written, instead of living inside one
    // hand-maintained scenario test that stops growing the day someone forgets
    // to extend it.

    /// Executes `callData` against the diamond as `actor` and asserts that the
    /// sum of every FeeCollected.amount emitted during THIS call equals the
    /// exact increase in feeRecipient's balance over the same call — no more
    /// (double-counted), no less (silent transfer). Returns the call's return
    /// data and raw logs so the caller can additionally assert on the specific
    /// event(s) it expected (id / payer / kind) via `_assertFeeCollected`.
    function _assertLedgerBalanced(address actor, bytes memory callData)
        internal returns (bytes memory returnData, Vm.Log[] memory logs)
    {
        uint256 before = usdc.balanceOf(feeRecipient);

        vm.recordLogs();
        vm.prank(actor);
        bool ok;
        (ok, returnData) = address(diamond).call(callData);
        if (!ok) {
            // Bubble the real revert reason instead of a generic message —
            // this helper is only used on happy paths, so a failure here
            // means the call itself broke, not the ledger invariant. Memory-safe:
            // only reads the existing `returnData` buffer, never writes past it.
            assembly ("memory-safe") { revert(add(returnData, 0x20), mload(returnData)) }
        }

        logs = vm.getRecordedLogs();

        // JobBoardFacet / ServiceBoardFacet / FactoryFacet each declare their
        // own FeeCollected — same signature text, so the selector (topic0) is
        // identical across all three; summing by topic0 alone therefore
        // covers all ten fee-collection call sites, not just one facet's.
        bytes32 feeCollectedTopic = ServiceBoardFacet.FeeCollected.selector;
        uint256 totalCollected;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(diamond)
                && logs[i].topics.length > 0
                && logs[i].topics[0] == feeCollectedTopic) {
                totalCollected += abi.decode(logs[i].data, (uint256));
            }
        }

        assertEq(totalCollected, usdc.balanceOf(feeRecipient) - before);
    }

    // ============================================================
    //  THE BALANCE IDENTITY — the diamond holds exactly what it books
    // ============================================================
    //
    // The convergence the boards audit proved by hand against Base Sepolia
    // (63 999 500 booked + 7 000 000 vault == 70 999 500 held, to the
    // microdollar), made into something a test can run.
    //
    // ⚠️ The two sides come from different places on purpose. The EXPECTED side
    // is the ledger — storage fields, one of them read as a raw slot because
    // JobBoard has no getter for it at all. The ACTUAL side is the token's own
    // `balanceOf`, a contract the boards do not write to except by transferring.
    // Neither is computed from the other, so an accounting change that forgets
    // a term cannot agree with itself.
    //
    // `undeliveredFee` is a term of that sum, and that is the whole reason it is
    // a stored number rather than a swallowed failure: money that stays on the
    // diamond has to be attributable to something, or the identity stops
    // holding and nobody can tell an owed dollar from a lost one.

    /// Base slot of `JobBoardStorage.Layout.jobFunds` — field 6 (nextJobId 0,
    /// jobs 1, clientJobs 2, applicants 3, hasApplied 4, _deprecated_receiptNFT
    /// 5, jobFunds 6). Not taken on trust: `_diamondLedger` asserts the slot it
    /// reads agrees with the fee the same job reports through `getJobFeeHeld`
    /// before it is believed — see `_assertJobFundsSlotIsWhereWeThink`.
    uint256 constant SLOT_JOB_FUNDS = 6;

    function _jobFunds(uint256 jobId) internal view returns (uint256) {
        bytes32 base = bytes32(uint256(JobBoardStorage.POSITION) + SLOT_JOB_FUNDS);
        return uint256(vm.load(address(diamond), keccak256(abi.encode(jobId, base))));
    }

    /// Everything the diamond says it is holding, added up.
    function _diamondLedger() internal view returns (uint256 total) {
        JobBoardFacet jb = JobBoardFacet(address(diamond));
        uint256 jobs = jb.totalJobs();
        for (uint256 i = 0; i < jobs; i++) {
            total += _jobFunds(i);
            total += jb.getJobFeeHeld(i);
        }

        ServiceBoardFacet sb = ServiceBoardFacet(address(diamond));
        uint256 requests = sb.totalRequests();
        for (uint256 i = 0; i < requests; i++) {
            total += sb.getRequestFunds(i);
            total += sb.getRequestFeeHeld(i);
        }

        total += FactoryFacet(address(diamond)).getUndeliveredFees();
    }

    /// The identity itself. Call it after anything that moves money.
    function _assertDiamondHoldsExactlyItsLedger(string memory whenWhat) internal view {
        assertEq(
            usdc.balanceOf(address(diamond)),
            _diamondLedger(),
            string.concat("the diamond's USDC does not add up to what it books: ", whenWhat)
        );
    }

    /// The raw-slot read above is the one part of the identity that could drift
    /// silently: a layout change moves the slot, the read returns zero, and the
    /// identity would then be satisfied by a diamond holding nothing. Anchoring
    /// it against a posted job whose amount is known makes that failure loud.
    function _assertJobFundsSlotIsWhereWeThink(uint256 jobId, uint256 expected) internal view {
        assertEq(_jobFunds(jobId), expected, "jobFunds slot offset drifted");
    }

    /// Finds the FeeCollected log (among logs returned by `_assertLedgerBalanced`)
    /// whose `id` topic equals `expectedId` and asserts its payer/kind/amount.
    /// Matching by id (rather than requiring exactly one FeeCollected in the
    /// whole call) is what lets this same helper cover acceptRequest's
    /// sibling-supersede path, where one call legitimately emits two
    /// FeeCollected events with two different ids.
    function _assertFeeCollected(
        Vm.Log[] memory logs,
        uint256 expectedId,
        address expectedPayer,
        uint8 expectedKind,
        uint256 expectedAmount
    ) internal view {
        bytes32 feeCollectedTopic = ServiceBoardFacet.FeeCollected.selector;
        uint256 matches;
        for (uint256 i = 0; i < logs.length; i++) {
            // Filter by emitter, as in _assertLedgerBalanced and as the replaced
            // vm.expectEmit(..., address(diamond)) used to do: today the topic
            // collides with nothing, but without this check a foreign event with
            // the same signature would pass for one of the diamond's own.
            if (logs[i].emitter == address(diamond)
                && logs[i].topics.length > 0
                && logs[i].topics[0] == feeCollectedTopic
                && uint256(logs[i].topics[1]) == expectedId) {
                matches++;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), expectedPayer);
                assertEq(uint256(logs[i].topics[3]), expectedKind);
                assertEq(abi.decode(logs[i].data, (uint256)), expectedAmount);
            }
        }
        assertEq(matches, 1);
    }
}
