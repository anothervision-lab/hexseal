// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// HEXSEAL — DeployFull.s.sol
// A full deployment from scratch: Diamond + every facet + SVGRenderer + init.
// Storage is ERC-7201 (namespaced slots): each facet holds its own slot through
// keccak256(abi.encode(uint256(keccak256("hexseal.<name>.storage")) - 1)) & ~bytes32(uint256(0xff)),
// see test/StorageLayout.t.sol.
//
// Regenerated on 2026-07-25 from the live ABIs (`forge inspect <Facet>
// methodIdentifiers`) after some forty incremental upgrades this file did not
// track. All 203 selectors of 12 facets are checked against
// test/DeployFullSelectors.t.sol — that test fails if this file and the live ABIs
// diverge again. The number here is the sum of the `new bytes4[](n)` literals in
// the builders below, and it has already gone stale fifteen times over.
//
// The chronicle is kept because the failure mode is the point, not the numbers:
// every time, a piece of work edited the LIST below and left this summary alone,
// and nothing caught it, because the post-check COUNTS the sum rather than
// comparing it against this paragraph. It read 148 when the factory grew from 13
// to 20; then 159, before the floor and the quote for the paid arbiter call; then
// 162 — the figure was not corrected in the same commit where the code grew to
// 167, on 31 July 2026; then 167, when getArbiterChatKeys arrived on 9 August
// 2026; then 168, when setArbiterChatKey arrived the same day; then 169, when the
// eight presentation-record functions arrived on 14 August 2026; then 177, when
// getSeatedBy/getSeatedCountBy arrived on 15 August 2026 — the provenance of an
// arbiter's seating; then 180, when getChiefBloc followed the same day — the
// chief's bloc ceiling; then 181, when getMaxClaimsPerArbiter arrived the same day
// — the ceiling on disputes in hand; then 187, when ArbiterRegistryFacet ran into
// 86.4% of the EIP-170 limit that day and arbiter suspension moved into a twelfth
// facet, ArbiterAccountabilityFacet — six new selectors; then 186, the same day,
// when getChiefArbiterAddress was taken off ArbiterAccountabilityFacet (it
// duplicated ArbiterRegistryFacet.getChiefArbiter, and the justification for it was
// simply wrong — through the proxy diamond both selectors went to one address);
// then 187 again, in the same commit, when getCleanVerdicts arrived in
// ArbiterRegistryFacet — a counter of unoverturned finalised verdicts, groundwork
// for a future "bond plus judging service" conversion when the DAO is switched on;
// then 192, the same day, for removal with a cause: removeArbiter was taken off
// ArbiterRegistryFacet (−1), getMaxArbiterMistakes was added there (+1, reading the
// same threshold from the other side), and ArbiterAccountabilityFacet gained
// removeArbiterForCause, getMistakeThreshold and three test getters for the light
// bench (+5) — and along with that addArbiter/setChiefArbiter began reverting while
// the DAO is active (the owner's decision, word for word: "no hand-picked ones"),
// with no change to the selector count; then 191, the same day, in review: three
// duplicate test getters (isRegisteredArbiterHere/getMistakeStreakOf/
// getNoResponseAtHere — exactly the defect getChiefArbiterAddress had been) were
// taken off ArbiterAccountabilityFacet, and two getters of its OWN constants were
// added instead (getMaxArbiterMistakesMirror, getDaoThresholdMirror — not
// duplicates: ArbiterRegistryFacet has no such numbers under those names), 9
// against the previous 10, with ArbiterRegistryFacet unchanged, so it is checked by
// the same test; then 196, the same day, for the chief's proposal — removal stays
// the owner's right (or daoAddress's after the handover) and the chief only signals
// with their address. ArbiterAccountabilityFacet gained proposeRemoval,
// withdrawProposal, hasLiveProposal, getRemovalProposal and getProposalTTL (+5, 14
// against the previous 9), with ArbiterRegistryFacet unchanged (the new
// removalProposals field is storage layout, not a selector); then 198, the same
// day, for the removed arbiter's right of reply — an accusation against a real
// address lies on chain forever, and respondToRemoval lets a removed arbiter put
// THEIR OWN digest beside it, cancelling and returning nothing.
// ArbiterAccountabilityFacet gained respondToRemoval and getRemovalReply (+2, 16
// against the previous 14) — it is also the facet's first gasless function and
// required a _msgSender() of its own; the new removalReply/removedAt fields are
// storage layout, not selectors; then 199, the same day, for getArbiterStanding —
// an arbiter's whole standing in one read instead of seven or eight separate
// requests, between which blocks pass and the picture disagrees with itself.
// ArbiterAccountabilityFacet gained one selector (+1, 17 against the previous 16);
// the set of fields is wider than the work was briefed for — cleanVerdicts and
// removedAt had appeared in storage while it was under way and both were added to
// the return value, plus hasLiveRemovalProposal (by calling hasLiveProposal, not by
// copying the formula) — no new storage fields were required, and
// ArbiterRegistryFacet was unchanged. The number 199 did NOT move when the facets
// were split (16 August 2026) and could not: that MOVED fourteen readers from
// ArbiterRegistryFacet into ArbiterAccountabilityFacet (69 → 55 and 17 → 31),
// adding and removing not one selector. The reason was the EIP-170 ceiling: the
// registry stood at 24 516 of 24 576, 60 bytes free, and the next piece of work did
// not fit into it; after the move, 23 238, with 1 338 to spare.
// Then 200, on 17 August 2026, for the cause IN WORDS. `Cause` is a numeric code,
// and the public record of a removal contained not one word; "removal with a cause"
// promised an explanation that existed nowhere. ArbiterAccountabilityFacet gained
// getMaxReasonBytes (+1, 32 against the previous 31) — the ceiling on words in
// BYTES, so that a form asks the chain for it rather than keeping a copy. Three
// already listed entrances changed SIGNATURE without adding selectors in this file
// (removeArbiterForCause/proposeRemoval gained a `string reason`, respondToRemoval
// a `string reply`): here the selectors are taken from the type. On chain that is a
// Replace of three old selectors rather than an Add — the composition of the cut is
// in script/UpgradeArbiterAccountability.s.sol. No new storage fields were
// required: the words live in EVENTS (RemovalReasonGiven/RemovalReplyGiven), their
// reader is the feed and the card, and storage would have cost more and moved the
// layout for nothing.
// ⚠️ HERE THE NUMBER STOPPED AT 200 AND WENT STALE TWICE IN A ROW, in silence: one
// piece of work (17 August 2026) appended getRemovalDelay and another (18 August)
// executeChainRemoval, and both times the LIST was edited and the summary above was
// not. The post-check did not suffer for it (test/DeployFullSelectors COUNTS the
// sum rather than comparing it against this paragraph), but a human reading the
// header would have been out by two. So: 201, on 17 August 2026, getRemovalDelay
// (+1, 32 against the previous 31), the reading of the 48-hour pause; 202, on
// 18 August 2026, executeChainRemoval (+1, 33 against 32), the quiet door leading
// into the common one.
// Then 203, on 21 August 2026, THE OTHER HALF OF THE RATIO. The mistake counter was
// a STREAK in a row, and a clean verdict reset it, so "mistake, mistake, clean" in
// a loop never reached the threshold, the automatic path never once fired, and
// `cleanVerdicts` grew all the while — an arbiter with thirteen overturns read
// BETTER from outside than an honest newcomer. A cumulative overturn count existed
// nowhere. ArbiterAccountabilityFacet gained getOverturnedVerdicts (+1, 35 against
// the previous 34), and the getArbiterStanding card returns the pair together — the
// reader divides. The new `overturnedVerdicts` field was appended TO THE END of
// ArbiterRegistryStorage.Data; the number has not one threshold or consequence (the
// owner's decision: the ladder is "visible → counted").
// To recount without relying on the eye:
//   grep -o "new bytes4\[\]([0-9]*)" script/DeployFull.s.sol \
//     | sed 's/.*(\([0-9]*\))/\1/' | awk '{s+=$1} END {print s}'
//
// Required BEFORE running:
//   TRUSTED_FORWARDER — an already deployed MinimalForwarder
//                        (script/DeployForwarder.s.sol); it must really exist on
//                        chain (the code is checked).
//   USDC_ADDRESS       — must really exist on chain (the code is checked);
//                        by default, the Base Sepolia test USDC.
//   FEE_RECIPIENT      — non-zero; without it the platform fees would go silently
//                        to the deployer key.
//   INITIAL_ARBITER    — non-zero; with not one arbiter, no dispute can be closed
//                        other than by a timeout refunding the client 100%
//                        (applyAsArbiter requires DAO mode, which a fresh
//                        deployment does not have, and addArbiter is
//                        onlyOwnerOrChief).
// All four are checked before a single vm.startBroadcast call — it is cheaper to
// stumble at once than after the script has already deployed twelve implementations
// and the Diamond.

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../src/SVGRenderer.sol";

contract DeployFull is Script {

    function run() external {
        address usdc             = vm.envOr("USDC_ADDRESS",      address(0x036CbD53842c5426634e7929541eC2318f3dCF7e));
        address feeRecipient     = vm.envOr("FEE_RECIPIENT",     address(0));
        address trustedForwarder = vm.envOr("TRUSTED_FORWARDER", address(0));
        address initialArbiter   = vm.envOr("INITIAL_ARBITER",   address(0));
        uint256 deployerKey      = vm.envUint("PRIVATE_KEY");
        address owner            = vm.addr(deployerKey);

        // ── Pre-flight checks — all BEFORE a single deployment ───────────────
        // Cheaper to stumble here than after the script has already burned gas on
        // twelve implementations and the Diamond itself.

        // initFactory() reverts FactoryZeroAddress() on a zero forwarder — the same
        // check here is simply cheaper by position.
        require(
            trustedForwarder != address(0),
            "DeployFull: TRUSTED_FORWARDER is zero - deploy MinimalForwarder first (script/DeployForwarder.s.sol) and export TRUSTED_FORWARDER"
        );
        // Not merely non-zero but really existing on this chain. A stale or
        // mistyped address passes the zero check silently and would deploy a diamond
        // with a mis-wired gasless path that breaks only on the first real relay —
        // not at deployment.
        require(
            trustedForwarder.code.length > 0,
            "DeployFull: TRUSTED_FORWARDER has no code on this chain"
        );

        // The same class of risk as the forwarder: USDC_ADDRESS defaults to a
        // hardcoded Base Sepolia address. A deployment onto the wrong chain quietly
        // binds a non-existent token, and every deal will revert on the very first
        // transferFrom — not at deployment, where it is cheap to catch.
        require(usdc.code.length > 0, "DeployFull: USDC_ADDRESS has no code on this chain");

        // With FEE_RECIPIENT missing, the fees used to leak silently to the deployer
        // key (the owner). On a live diamond those are two DIFFERENT addresses — such
        // a fallback here would be a wrong configuration that looks like a successful
        // deployment.
        require(
            feeRecipient != address(0),
            "DeployFull: FEE_RECIPIENT is zero - platform fees would silently route to the deployer key"
        );

        // Without this the diamond starts with an EMPTY arbiter registry:
        // applyAsArbiter() requires isDaoActive(), that is, owner.activateDAO() and
        // nothing else (since 26 August 2026 the earned threshold no longer switches
        // it on) — which is untrue on a fresh deployment, while addArbiter is
        // onlyOwnerOrChief and chiefArbiter is zero too. With not one arbiter,
        // commitDisputeClaim/claimDispute revert NotArbiter() for everybody, and
        // triggerArbiterTimeout() after the 4-day window becomes the only terminal
        // outcome of a dispute — a 100% refund to the client. Combined with
        // raiseDispute() that is an unconditional "undo" on any work already
        // delivered.
        require(
            initialArbiter != address(0),
            "DeployFull: INITIAL_ARBITER is zero - a diamond with no arbiter resolves every dispute as a client refund"
        );

        vm.startBroadcast(deployerKey);

        // ── 1. Deploy every implementation ───────────────────────────────────
        DiamondCutFacet        cutFacet     = new DiamondCutFacet();
        DiamondLoupeFacet      loupeFacet   = new DiamondLoupeFacet();
        OwnershipFacet         ownFacet     = new OwnershipFacet();
        RegistryFacet          regFacet     = new RegistryFacet();
        FactoryFacet           facFacet     = new FactoryFacet();
        JobBoardFacet          jobBoard     = new JobBoardFacet();
        ServiceBoardFacet      serviceBoard = new ServiceBoardFacet();
        ArbiterRegistryFacet   arbiterFacet = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet accFacet = new ArbiterAccountabilityFacet();
        ArbiterApplicationsFacet appFacet = new ArbiterApplicationsFacet();
        DealMetadataFacet      metaFacet    = new DealMetadataFacet();
        JobReceiptFacet        receiptFacet = new JobReceiptFacet();
        ReputationFacet        repFacet     = new ReputationFacet();
        SVGRenderer            svgRenderer  = new SVGRenderer();

        console.log("--- Implementations ---");
        console.log("DiamondCutFacet:      ", address(cutFacet));
        console.log("DiamondLoupeFacet:    ", address(loupeFacet));
        console.log("OwnershipFacet:       ", address(ownFacet));
        console.log("RegistryFacet:        ", address(regFacet));
        console.log("FactoryFacet:         ", address(facFacet));
        console.log("JobBoardFacet:        ", address(jobBoard));
        console.log("ServiceBoardFacet:    ", address(serviceBoard));
        console.log("ArbiterRegistryFacet: ", address(arbiterFacet));
        console.log("ArbiterAccountabilityFacet:", address(accFacet));
        console.log("ArbiterApplicationsFacet:", address(appFacet));
        console.log("DealMetadataFacet:    ", address(metaFacet));
        console.log("JobReceiptFacet:      ", address(receiptFacet));
        console.log("ReputationFacet:      ", address(repFacet));
        console.log("SVGRenderer:          ", address(svgRenderer));

        // ── 2. The base facets for the Diamond constructor ────────────────────
        // (DiamondCut, DiamondLoupe, Ownership, Registry, Factory)
        // supportsInterface here comes from DiamondLoupeFacet and stays that way; the
        // ERC-721 interfaces for the receipt NFT are registered in the mapping by the
        // Diamond constructor
        IDiamondCut.FacetCut[] memory initCuts = buildInitCuts(
            address(cutFacet), address(loupeFacet), address(ownFacet), address(regFacet), address(facFacet)
        );

        // ── 3. Deploy the Diamond ─────────────────────────────────────────────
        DiamondProxy diamond = new DiamondProxy(owner, initCuts, address(0), "");
        console.log("--- Diamond ---");
        console.log("DiamondProxy:         ", address(diamond));

        // Agreement is deployed ONCE as an implementation contract; each deal gets a
        // 45-byte EIP-1167 clone. The constructor locks the implementation, so it
        // cannot itself be initialised.
        Agreement          agreementImpl = new Agreement();
        console.log("Agreement impl:       ", address(agreementImpl));

        // AgreementDeployer needs Diamond as authorizedCaller — deploy after Diamond is known
        AgreementDeployer  agDeployer     = new AgreementDeployer(address(diamond), address(agreementImpl));
        console.log("AgreementDeployer:    ", address(agDeployer));

        // ── 4. Initialise Registry + Factory ─────────────────────────────────
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(
            usdc,
            feeRecipient,
            trustedForwarder,
            address(diamond),
            address(agDeployer)
        );

        // ── 5. Add the remaining facets in one diamondCut ────────────────────
        // Order: JobBoard, ServiceBoard, ArbiterRegistry,
        //        ArbiterAccountability, DealMetadata, JobReceiptFacet,
        //        ReputationFacet
        IDiamondCut.FacetCut[] memory cuts2 = buildRemainingCuts(
            address(jobBoard),
            address(serviceBoard),
            address(arbiterFacet),
            address(accFacet),
            address(appFacet),
            address(metaFacet),
            address(receiptFacet),
            address(repFacet)
        );

        IDiamondCut(address(diamond)).diamondCut(cuts2, address(0), "");

        // ── 6. Link the SVGRenderer ───────────────────────────────────────────
        JobReceiptFacet(address(diamond)).setSvgRenderer(address(svgRenderer));

        // ── 7. The first arbiter ──────────────────────────────────────────────
        // Without this, a round of disputes cannot be closed other than by a timeout
        // refunding the client (see the note at require(initialArbiter != address(0))
        // above). chiefArbiter is NOT set — on a live diamond it stays zero.
        ArbiterRegistryFacet(address(diamond)).addArbiter(initialArbiter);

        vm.stopBroadcast();

        // ── 8. The result ─────────────────────────────────────────────────────
        uint256 feeBps = FactoryFacet(address(diamond)).getFeeBps();
        uint256 feeFloor = FactoryFacet(address(diamond)).getFeeFloor();
        address[] memory arbiters = ArbiterRegistryFacet(address(diamond)).getArbiters();

        console.log("\n======== HEXSEAL DEPLOYMENT COMPLETE ========");
        console.log("DiamondProxy:  ", address(diamond));
        console.log("SVGRenderer:   ", address(svgRenderer));
        console.log("USDC:          ", usdc);
        console.log("FeeRecipient:  ", feeRecipient);
        console.log("Forwarder:     ", trustedForwarder);
        console.log("Owner:         ", owner);
        console.log("Fee bps:       ", feeBps);
        console.log("Fee floor:     ", feeFloor);
        console.log("--- Arbiters ---");
        console.log("Count:         ", arbiters.length);
        for (uint256 i = 0; i < arbiters.length; i++) {
            console.log("  Arbiter:     ", arbiters[i]);
        }
        console.log("=============================================");
        console.log("Update your .env:");
        console.log("DIAMOND_ADDRESS=", address(diamond));
    }

    // ════════════════════════════════════════════════════════════════════════
    // Building the FacetCut[] — extracted into public pure functions so that
    // test/DeployFullSelectors.t.sol can compare them against the live ABIs without
    // running the deployment again. The single source of truth: run() above builds
    // its cuts through these very functions and duplicates nothing by hand.
    // ════════════════════════════════════════════════════════════════════════

    function buildInitCuts(
        address cutFacetAddr,
        address loupeFacetAddr,
        address ownFacetAddr,
        address regFacetAddr,
        address facFacetAddr
    ) public pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = _cut(cutFacetAddr,   IDiamondCut.FacetCutAction.Add, cutFacetSelectors());
        cuts[1] = _cut(loupeFacetAddr, IDiamondCut.FacetCutAction.Add, loupeFacetSelectors());
        cuts[2] = _cut(ownFacetAddr,   IDiamondCut.FacetCutAction.Add, ownershipFacetSelectors());
        cuts[3] = _cut(regFacetAddr,   IDiamondCut.FacetCutAction.Add, registryFacetSelectors());
        cuts[4] = _cut(facFacetAddr,   IDiamondCut.FacetCutAction.Add, factoryFacetSelectors());
    }

    function buildRemainingCuts(
        address jobBoardAddr,
        address serviceBoardAddr,
        address arbiterFacetAddr,
        address accountabilityFacetAddr,
        address applicationsFacetAddr,
        address metaFacetAddr,
        address receiptFacetAddr,
        address reputationFacetAddr
    ) public pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](8);
        cuts[0] = _cut(jobBoardAddr,             IDiamondCut.FacetCutAction.Add, jobBoardFacetSelectors());
        cuts[1] = _cut(serviceBoardAddr,         IDiamondCut.FacetCutAction.Add, serviceBoardFacetSelectors());
        cuts[2] = _cut(arbiterFacetAddr,         IDiamondCut.FacetCutAction.Add, arbiterRegistryFacetSelectors());
        cuts[3] = _cut(accountabilityFacetAddr,  IDiamondCut.FacetCutAction.Add, arbiterAccountabilityFacetSelectors());
        cuts[4] = _cut(applicationsFacetAddr,    IDiamondCut.FacetCutAction.Add, arbiterApplicationsFacetSelectors());
        cuts[5] = _cut(metaFacetAddr,            IDiamondCut.FacetCutAction.Add, dealMetadataFacetSelectors());
        cuts[6] = _cut(receiptFacetAddr,         IDiamondCut.FacetCutAction.Add, jobReceiptFacetSelectors());
        cuts[7] = _cut(reputationFacetAddr,      IDiamondCut.FacetCutAction.Add, reputationFacetSelectors());
    }

    // ── Per-facet selector arrays (ground truth: `forge inspect <Facet> methodIdentifiers`) ──

    // DiamondCutFacet — 1 selector
    function cutFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = IDiamondCut.diamondCut.selector;
    }

    // DiamondLoupeFacet — 5 selectors
    function loupeFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](5);
        sels[0] = IDiamondLoupe.facets.selector;
        sels[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        sels[2] = IDiamondLoupe.facetAddresses.selector;
        sels[3] = IDiamondLoupe.facetAddress.selector;
        sels[4] = IERC165.supportsInterface.selector;
    }

    // OwnershipFacet — 4 selectors
    function ownershipFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](4);
        sels[0] = OwnershipFacet.transferOwnership.selector;
        sels[1] = OwnershipFacet.owner.selector;
        sels[2] = OwnershipFacet.acceptOwnership.selector;
        sels[3] = OwnershipFacet.pendingOwner.selector;
    }

    // RegistryFacet — 13 selectors
    function registryFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](13);
        sels[0]  = RegistryFacet.initRegistry.selector;
        sels[1]  = RegistryFacet.register.selector;
        sels[2]  = RegistryFacet.updateStatus.selector;
        sels[3]  = RegistryFacet.setAuthorizedFactory.selector;
        sels[4]  = RegistryFacet.hasActivePair.selector;
        sels[5]  = RegistryFacet.getActivePair.selector;
        sels[6]  = RegistryFacet.getRecord.selector;
        sels[7]  = RegistryFacet.getByClient.selector;
        sels[8]  = RegistryFacet.getByExecutor.selector;
        sels[9]  = RegistryFacet.getActive.selector;
        sels[10] = RegistryFacet.getDisputed.selector;
        sels[11] = RegistryFacet.totalAgreements.selector;
        sels[12] = RegistryFacet.authorizedFactory.selector;
    }

    // FactoryFacet — 23 selectors (setPaused/isPaused/getProtocolArbiter/
    // setProtocolArbiter/getArbitrationThreshold/setArbitrationThreshold were deleted
    // and are no longer in the ABI; 21 -> 23 on 25 August 2026:
    // getUndeliveredFees/withdrawUndeliveredFees — a fee the recipient would not take
    // is now a debt to the protocol rather than a person's locked refund)
    function factoryFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](23);
        sels[0]  = FactoryFacet.initFactory.selector;
        sels[1]  = FactoryFacet.deployAgreement.selector;
        sels[2]  = FactoryFacet.deployAndFund.selector;
        sels[3]  = FactoryFacet.setRegionFee.selector;
        sels[4]  = FactoryFacet.setFeeRecipient.selector;
        sels[5]  = FactoryFacet.setTrustedForwarder.selector;
        sels[6]  = FactoryFacet.setAgreementDeployer.selector;
        sels[7]  = FactoryFacet.getRegionFee.selector;
        sels[8]  = FactoryFacet.getAllFees.selector;
        sels[9]  = FactoryFacet.getFeeRecipient.selector;
        sels[10] = FactoryFacet.getTrustedForwarder.selector;
        sels[11] = FactoryFacet.getUsdc.selector;
        sels[12] = FactoryFacet.getAgreementDeployer.selector;
        sels[13] = FactoryFacet.setFeeBps.selector;
        sels[14] = FactoryFacet.setFeeFloor.selector;
        sels[15] = FactoryFacet.setMaxPendingRequests.selector;
        sels[16] = FactoryFacet.quoteFee.selector;
        sels[17] = FactoryFacet.getFeeBps.selector;
        sels[18] = FactoryFacet.getFeeFloor.selector;
        sels[19] = FactoryFacet.getMaxPendingRequests.selector;
        // A one-shot seeding of the fee model through the diamondCut's
        // `_init`/`_calldata`. It is not called on a fresh deployment (initFactory has
        // already set everything), but it must be mounted: without it an upgrade of a
        // live diamond has no way to set feeFloor in the same transaction as the cut.
        sels[20] = FactoryFacet.initFeeModel.selector;
        // The fee the feeRecipient would not take: it is visible and it can be
        // collected. Without both, a board would push a debt into a field nobody reads.
        sels[21] = FactoryFacet.getUndeliveredFees.selector;
        sels[22] = FactoryFacet.withdrawUndeliveredFees.selector;
    }

    // JobBoardFacet — 13 selectors
    function jobBoardFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](13);
        sels[0]  = JobBoardFacet.mintJobWithPermit.selector;
        sels[1]  = JobBoardFacet.mintJob.selector;
        sels[2]  = JobBoardFacet.applyForJob.selector;
        sels[3]  = JobBoardFacet.withdrawApplication.selector;
        sels[4]  = JobBoardFacet.acceptApplicant.selector;
        sels[5]  = JobBoardFacet.cancelJob.selector;
        sels[6]  = JobBoardFacet.editJob.selector;
        sels[7]  = JobBoardFacet.getJob.selector;
        sels[8]  = JobBoardFacet.getClientJobs.selector;
        sels[9]  = JobBoardFacet.getApplicants.selector;
        sels[10] = JobBoardFacet.totalJobs.selector;
        sels[11] = JobBoardFacet.getOpenJobs.selector;
        sels[12] = JobBoardFacet.getJobFeeHeld.selector;
    }

    // ServiceBoardFacet — 25 selectors
    function serviceBoardFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](25);
        sels[0]  = ServiceBoardFacet.mintService.selector;
        sels[1]  = ServiceBoardFacet.mintServiceWithPermit.selector;
        sels[2]  = ServiceBoardFacet.removeService.selector;
        sels[3]  = ServiceBoardFacet.pauseService.selector;
        sels[4]  = ServiceBoardFacet.unpauseService.selector;
        sels[5]  = ServiceBoardFacet.editService.selector;
        sels[6]  = ServiceBoardFacet.requestService.selector;
        sels[7]  = ServiceBoardFacet.requestServiceWithPermit.selector;
        sels[8]  = ServiceBoardFacet.acceptRequest.selector;
        sels[9]  = ServiceBoardFacet.rejectRequest.selector;
        sels[10] = ServiceBoardFacet.cancelRequest.selector;
        sels[11] = ServiceBoardFacet.getService.selector;
        sels[12] = ServiceBoardFacet.getExecutorServices.selector;
        sels[13] = ServiceBoardFacet.getServiceClients.selector;
        sels[14] = ServiceBoardFacet.totalServices.selector;
        sels[15] = ServiceBoardFacet.getRequest.selector;
        sels[16] = ServiceBoardFacet.getServiceRequests.selector;
        sels[17] = ServiceBoardFacet.getClientRequests.selector;
        sels[18] = ServiceBoardFacet.totalRequests.selector;
        sels[19] = ServiceBoardFacet.getRequestFunds.selector;
        sels[20] = ServiceBoardFacet.getActiveServices.selector;
        sels[21] = ServiceBoardFacet.getPendingRequests.selector;
        sels[22] = ServiceBoardFacet.getPendingRequestIdsByClientAndExecutor.selector;
        sels[23] = ServiceBoardFacet.getRequestFeeHeld.selector;
        sels[24] = ServiceBoardFacet.getPendingRequestCount.selector;
    }

    // ArbiterRegistryFacet — 57 selectors
    function arbiterRegistryFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](59);

        // DAO mode
        sels[0] = ArbiterRegistryFacet.activateDAO.selector;
        sels[1] = ArbiterRegistryFacet.applyAsArbiter.selector;
        sels[2] = ArbiterRegistryFacet.resignAsArbiter.selector;

        // Admin: managing arbiters
        sels[3] = ArbiterRegistryFacet.setChiefArbiter.selector;
        sels[4] = ArbiterRegistryFacet.addArbiter.selector;

        // Claiming a dispute (commit-reveal)
        sels[5] = ArbiterRegistryFacet.commitDisputeClaim.selector;
        sels[6] = ArbiterRegistryFacet.claimDispute.selector;
        sels[7] = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        sels[8] = ArbiterRegistryFacet.clearDisputeClaim.selector;

        // The verdict
        sels[9] = ArbiterRegistryFacet.submitVerdict.selector;
        sels[10] = ArbiterRegistryFacet.finalizeVerdict.selector;
        sels[11] = ArbiterRegistryFacet.overturnVerdict.selector;
        sels[12] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        sels[13] = ArbiterRegistryFacet.freezeVerdict.selector;
        sels[14] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        sels[15] = ArbiterRegistryFacet.clearStuckVerdict.selector;

        // The appeal
        sels[16] = ArbiterRegistryFacet.raiseAppeal.selector;
        sels[17] = ArbiterRegistryFacet.voteOnAppeal.selector;
        sels[18] = ArbiterRegistryFacet.resolveAppeal.selector;

        // Rewards
        sels[19] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        sels[20] = ArbiterRegistryFacet.fundVault.selector;
        sels[21] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        sels[22] = ArbiterRegistryFacet.setDAOAddress.selector;

        // Views
        sels[23] = ArbiterRegistryFacet.isDaoActive.selector;
        sels[24] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        sels[25] = ArbiterRegistryFacet.getDaoThreshold.selector;
        sels[26] = ArbiterRegistryFacet.getChiefArbiter.selector;
        sels[27] = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        sels[28] = ArbiterRegistryFacet.getArbiters.selector;
        sels[29] = ArbiterRegistryFacet.getDisputeClaimer.selector;
        sels[30] = ArbiterRegistryFacet.getClaimCommitment.selector;
        sels[31] = ArbiterRegistryFacet.getPendingVerdict.selector;
        sels[32] = ArbiterRegistryFacet.getVaultBalance.selector;
        sels[33] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        sels[34] = ArbiterRegistryFacet.getDAOAddress.selector;
        sels[35] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        sels[36] = ArbiterRegistryFacet.getAppealVotes.selector;
        sels[37] = ArbiterRegistryFacet.hasVotedOnAppeal.selector;

        // The dispute fee (3% of the disputed amount, computed by Agreement) — split 80/20 arbiter/treasury
        sels[38] = ArbiterRegistryFacet.creditDisputeFee.selector;
        sels[39] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        sels[40] = ArbiterRegistryFacet.getTreasurySlice.selector;

        // The paid arbiter call: the floor and the quote for the top-up to it
        sels[41] = ArbiterRegistryFacet.setArbiterFloor.selector;
        sels[42] = ArbiterRegistryFacet.getArbiterFloor.selector;
        sels[43] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;

        // The paid arbiter call: payment and the soft refund of the top-up
        sels[44] = ArbiterRegistryFacet.fundDispute.selector;
        sels[45] = ArbiterRegistryFacet.getDisputeBounty.selector;
        sels[46] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        sels[47] = ArbiterRegistryFacet.getRefundableBounty.selector;

        // The arbiter's chat keys (9 August 2026)
        sels[48] = ArbiterRegistryFacet.setArbiterChatKey.selector;

        // The record "asked, got no answer" and the presentation digest
        // (14 August 2026). On the live diamond these eight arrive with the cut in
        // script/UpgradePresentationRecord.s.sol.
        //
        // ⚠️ Only the WRITES stayed here, plus the getter for the NO_RESPONSE_FLOOR
        // constant: five readers of this group (getDisputeClaimedAt, getNoResponseAt,
        // getPresentationDigests/Page/Count) moved into ArbiterAccountabilityFacet on
        // 16 August 2026. getNoResponseFloor deliberately did not move — it reads a
        // private constant that recordNoResponse in the same file applies.
        sels[49] = ArbiterRegistryFacet.recordNoResponse.selector;
        sels[50] = ArbiterRegistryFacet.getNoResponseFloor.selector;
        sels[51] = ArbiterRegistryFacet.recordPresentationDigest.selector;

        // The seating provenance (getSeatedBy/getSeatedCountBy) moved into
        // ArbiterAccountabilityFacet on 16 August 2026 — WRITING the provenance
        // (addArbiter, ArbiterRegistryStorage.clearSeat) stayed here, only the reading
        // moved.

        // The chief's bloc ceiling (15 August 2026): addArbiter now forbids the chief
        // to assemble a bloc the size of an appeal quorum. It arrives on the live
        // diamond with a separate upgrade cut, not with this script.
        sels[52] = ArbiterRegistryFacet.getChiefBloc.selector;

        // The ceiling on disputes in hand (15 August 2026): claimDispute refuses an
        // arbiter who already holds MAX_CLAIMS_PER_ARBITER open disputes — fee farming
        // (income without work regardless of the verdict) cannot grow by the number of
        // claims. It arrives on the live diamond with a separate upgrade cut, not with
        // this script.
        sels[53] = ArbiterRegistryFacet.getMaxClaimsPerArbiter.selector;

        // The teeth of a suspension (15 August 2026):
        // claimDispute/resignAsArbiter/finalizeVerdict now refuse a suspended arbiter
        // — that is behaviour, not a selector. The getCleanVerdicts counter moved into
        // ArbiterAccountabilityFacet on 16 August 2026; finalizeVerdict here writes it.

        // The judging-mistake streak threshold read from this side (15 August 2026):
        // it matches ArbiterAccountabilityFacet.getMistakeThreshold() and is compared
        // by test_MistakeThresholdMatchesRegistry.
        sels[54] = ArbiterRegistryFacet.getMaxArbiterMistakes.selector;

        // Handing over the DAO address in two steps (26 August 2026): setDAOAddress
        // above became a PROPOSAL, and the rights pass only when the named address
        // sends acceptDAOAddress() itself. It arrives on the live diamond with a
        // separate upgrade cut, not with this script.
        sels[55] = ArbiterRegistryFacet.acceptDAOAddress.selector;
        sels[56] = ArbiterRegistryFacet.getPendingDAOAddress.selector;

        // The arbiter vault's discount on the dispute top-up (29 August 2026). The
        // size of the discount is a STORED number rather than a constant: the protocol
        // has had zero disputes in its whole life, three dollars is a starting point,
        // and it has to be changed with one transaction rather than by replacing a
        // facet. The subtraction itself lives inside quoteDisputeTopUp (its selector is
        // already above) — the single owner of the number the screen reads too.
        sels[57] = ArbiterRegistryFacet.setDisputeDiscount.selector;
        sels[58] = ArbiterRegistryFacet.getDisputeDiscount.selector;
    }

    // ArbiterAccountabilityFacet — 35 selectors (the number on this line read "31"
    // and went stale four times over: getMaxReasonBytes, getRemovalDelay,
    // executeChainRemoval, getOverturnedVerdicts. Count not by it but by the
    // `new bytes4[](n)` literal on the line below — that one is single and is edited
    // together with the list itself.)
    //
    // The facet began on 15 August 2026 with five selectors; a sixth,
    // getChiefArbiterAddress, was taken off the same day — see the comment below.
    // Removal with a cause added five more that day (removal plus four views); review
    // then took off three duplicate test getters (isRegisteredArbiterHere,
    // getMistakeStreakOf, getNoResponseAtHere — exactly the defect
    // getChiefArbiterAddress had been) and added two mirror getters of constants
    // (getMaxArbiterMistakesMirror, getDaoThresholdMirror) — 10 → 7 → 9; the chief's
    // proposal added five that day (proposeRemoval/withdrawProposal/hasLiveProposal/
    // getRemovalProposal/getProposalTTL, +5 → 14); the removed arbiter's right of reply
    // added two (respondToRemoval/getRemovalReply, +2 → 16); and getArbiterStanding
    // added one (+1 → 17) — an arbiter's whole standing in one read (xp, cleanStreak,
    // mistakeStreak, bond, seatedBy, suspendedUntil, openClaims, cleanVerdicts,
    // removedAt, hasLiveRemovalProposal) instead of seven or eight separate requests
    // that could disagree with each other by a block. A separate facet and not an
    // addition to ArbiterRegistryFacet: that one occupied 21 227 of 24 576 bytes
    // (86.4%) and there was not enough room. It shares the same ArbiterRegistryStorage
    // namespace — no data is moved.
    function arbiterAccountabilityFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](36);
        sels[0] = ArbiterAccountabilityFacet.suspendArbiter.selector;
        sels[1] = ArbiterAccountabilityFacet.liftSuspension.selector;
        sels[2] = ArbiterAccountabilityFacet.isSuspended.selector;
        sels[3] = ArbiterAccountabilityFacet.getSuspendedUntil.selector;
        sels[4] = ArbiterAccountabilityFacet.getSuspensionWindow.selector;
        // getChiefArbiterAddress WAS TAKEN OFF (15 August 2026): it duplicated
        // ArbiterRegistryFacet.getChiefArbiter() — through the proxy diamond both
        // selectors went to one and the same address, and the justification "so the
        // client need not touch a second facet" was simply wrong. The real reason it
        // appeared was a light test bench with the facets deployed separately; the
        // ArbiterSuspension suite now checks the chiefArbiter slot offset with a direct
        // vm.load, without introducing a permanent public selector for a test's sake.

        // Removal with a cause (15 August 2026): three codes the chain checks itself,
        // three require a digest of the evidence and are marked verifiedByChain=false.
        // The right of removal travels to the owner along with the DAO activation and
        // is handed to daoAddress — it is not locked away into emptiness.
        sels[5] = ArbiterAccountabilityFacet.removeArbiterForCause.selector;

        // Mirror getters of constants (from review): getMistakeThreshold is the
        // threshold of a MANUAL removal (MAX_ARBITER_MISTAKES − 1, strictly below the
        // automatic one — otherwise OverturnedVerdicts/Timeouts are unreachable).
        // getMaxArbiterMistakesMirror/getDaoThresholdMirror are local mirrors of
        // ArbiterRegistryFacet's numbers, needed by tests to compare both halves of the
        // tie against the production numbers rather than only against each other. These
        // are NOT duplicates of the three taken off above: those read LIVE STATE
        // already available through ArbiterRegistryFacet (the same defect as
        // getChiefArbiterAddress); these read the facet's OWN private constants, which
        // are reachable from nowhere else.
        sels[6] = ArbiterAccountabilityFacet.getMistakeThreshold.selector;
        sels[7] = ArbiterAccountabilityFacet.getMaxArbiterMistakesMirror.selector;
        sels[8] = ArbiterAccountabilityFacet.getDaoThresholdMirror.selector;

        // The chief's proposal (15 August 2026): removal stays the owner's
        // irreversible right (or daoAddress's after the handover) — the chief puts only
        // a SIGNAL record on chain, with their address. Execution
        // (removeArbiterForCause) does not read removalProposals — the owner must pass
        // the cause code and the digest again, in their own arguments; the only tie is
        // that the proposal is cleared on a successful removal of the same arbiter.
        sels[9]  = ArbiterAccountabilityFacet.proposeRemoval.selector;
        sels[10] = ArbiterAccountabilityFacet.withdrawProposal.selector;
        sels[11] = ArbiterAccountabilityFacet.hasLiveProposal.selector;
        sels[12] = ArbiterAccountabilityFacet.getRemovalProposal.selector;
        sels[13] = ArbiterAccountabilityFacet.getProposalTTL.selector;

        // The accused's right of reply (15 August 2026; since 19 August a reply is
        // accepted DURING the pause as well, not only after a removal): an accusation
        // against a real address lies on chain forever, and respondToRemoval is the
        // ONLY gasless function of this facet (it is called by the accused or removed
        // arbiter, an ordinary person) and reads the sender through its own
        // _msgSender().
        sels[14] = ArbiterAccountabilityFacet.respondToRemoval.selector;
        sels[15] = ArbiterAccountabilityFacet.getRemovalReply.selector;

        // An arbiter's standing in one read (15 August 2026): one view instead of
        // seven or eight separate requests that could disagree with each other by a
        // block — the bond read before a removal and the status after.
        sels[16] = ArbiterAccountabilityFacet.getArbiterStanding.selector;

        // ── FOURTEEN READERS OUT OF THE REGISTRY (16 August 2026) ──
        // ArbiterRegistryFacet ran into the EIP-170 ceiling (24 516 of 24 576, 60
        // free) — the next piece of work physically did not fit into it. The readers
        // about an arbiter's behaviour, standing and evidence moved here; the registry
        // became 23 238 (1 338 to spare) and this facet 6 327.
        //
        // ⚠️ THIS IS A MOVE, NOT NEW ENTRANCES. The diamond's total set of selectors
        // did not change: 86 before and 86 after, the same set byte for byte (the
        // registry 69 → 55, here 17 → 31). From outside a caller sees nothing.
        //
        // An arbiter's behaviour and standing
        sels[17] = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;
        sels[18] = ArbiterAccountabilityFacet.getCleanVerdicts.selector;
        sels[19] = ArbiterAccountabilityFacet.getArbiterBond.selector;
        sels[20] = ArbiterAccountabilityFacet.getOpenClaimCount.selector;
        sels[21] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        sels[22] = ArbiterAccountabilityFacet.getArbiterDeals.selector;

        // The seating provenance (the reading moved here on 16 August 2026)
        sels[23] = ArbiterAccountabilityFacet.getSeatedBy.selector;
        sels[24] = ArbiterAccountabilityFacet.getSeatedCountBy.selector;

        // Evidence: chat keys, the presentation anchor, the record of silence, and the
        // digests (the writes stayed in the registry)
        sels[25] = ArbiterAccountabilityFacet.getArbiterChatKeys.selector;
        sels[26] = ArbiterAccountabilityFacet.getDisputeClaimedAt.selector;
        sels[27] = ArbiterAccountabilityFacet.getNoResponseAt.selector;
        sels[28] = ArbiterAccountabilityFacet.getPresentationDigests.selector;
        sels[29] = ArbiterAccountabilityFacet.getPresentationDigestCount.selector;
        sels[30] = ArbiterAccountabilityFacet.getPresentationDigestsPage.selector;

        // ── The cause in words (17 August 2026) ──
        // The ceiling on words in BYTES, asked of the chain. A copy of the number on
        // the client would drift apart in silence and would give a person a rejected
        // transaction instead of a hint in the field. The same work changed the
        // SIGNATURES of three already listed entrances (removeArbiterForCause,
        // proposeRemoval and respondToRemoval gained a `string`) — here the selectors
        // are taken from the type, so the lines above needed no editing. On chain it is
        // still an Add and not a Replace: the cut of this branch has not been made, not
        // one of the three old selectors is mounted in the diamond — only the VALUE of
        // the selector inside the Add group of
        // script/UpgradeArbiterAccountability.s.sol changed.
        sels[31] = ArbiterAccountabilityFacet.getMaxReasonBytes.selector;

        // ── The 48-hour pause (design of 17 August 2026) ──
        // Removal stopped being a single button: it now runs only through a
        // proposal that has sat for REMOVAL_DELAY and is still inside
        // PROPOSAL_TTL, and the cause at execution must match the one proposed.
        // The pause itself is a rule, not a selector; what is mounted here is
        // the READING of it, so the form can say "19 hours to go" and show the
        // button as live at the same second the chain does. A copy of the
        // number in the frontend would drift in silence.
        sels[32] = ArbiterAccountabilityFacet.getRemovalDelay.selector;

        // ── The quiet door leads into the common one (18 August 2026) ──
        // The third judicial mistake no longer unseats. It suspends at once and
        // lays a removal proposal in the CHAIN'S OWN NAME; once the 48 hours
        // have passed, anyone may press this — the chain proved the cause
        // itself, so pressing carries no discretion. One argument, and it
        // refuses any accusation a human laid: that one is still the removal
        // authority's to execute through removeArbiterForCause.
        sels[33] = ArbiterAccountabilityFacet.executeChainRemoval.selector;

        // ── The other half of the fraction (21 August 2026) ──
        // `cleanVerdicts` alone showed a patient bad arbiter as BETTER than an
        // honest newcomer: "mistake, mistake, clean" round and round grows the
        // service record and never carries the streak to its threshold, because
        // the streak is a streak and a clean verdict clears it. Nothing counted
        // the overturns at all. This reading is the total; it decides nothing
        // and gates nothing — getArbiterStanding hands it out beside
        // getCleanVerdicts and the READER divides.
        sels[34] = ArbiterAccountabilityFacet.getOverturnedVerdicts.selector;

        // ── The bank's share of a dispute top-up (29 August 2026) ──
        // A bare storage read of a field ArbiterRegistryFacet owns and writes.
        // It is mounted HERE and not there for bytes and for nothing else: the
        // registry stands 90 bytes under the EIP-170 ceiling and could not hold
        // one more function. Same storage, same POSITION, same diamond address.
        sels[35] = ArbiterAccountabilityFacet.getDisputeSubsidy.selector;
    }

    // ArbiterApplicationsFacet — 11 selectors (24 August 2026).
    //
    // The thirteenth facet. The door into the arbiter corps before the DAO is
    // switched on: until it, the only entrance was addArbiter, and applyAsArbiter
    // reverts DAONotActive on its first line — that is, NOBODY could file an
    // application. The self-enrolment gate measures a record (3 000 XP ≈ thirty
    // deals), and at the start there is no record; lowering the threshold would leave
    // the bond as the filter, that is, would sell the seat. Hence a decision made by
    // hand — and it ends with an EVENT: the isDaoActive() ratchet closes this door
    // with the same DAO activation that closes addArbiter.
    //
    // Why a separate facet rather than an addition to one of the two neighbours — see
    // the header of src/facets/ArbiterApplicationsFacet.sol: the registry has 1 207
    // bytes to spare, and the accountability facet has room but its name is already
    // half untrue, and a second layer of that untruth is not worth introducing.
    function arbiterApplicationsFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](11);

        // The applicant's doors are BOTH gasless (ERC-2771): somebody worth seating
        // has a record of deals, not necessarily an ETH balance.
        sels[0] = ArbiterApplicationsFacet.applyForArbiterSeat.selector;
        sels[1] = ArbiterApplicationsFacet.withdrawArbiterApplication.selector;

        // The decision doors are administrative (the owner or, before the DAO, the
        // chief) and read a raw msg.sender. The bond is debited HERE, on approval, and
        // not on filing: the decision is made by a human by hand, and by not answering
        // they would be holding somebody else's money for who knows how long.
        sels[2] = ArbiterApplicationsFacet.approveArbiterApplication.selector;
        sels[3] = ArbiterApplicationsFacet.rejectArbiterApplication.selector;

        // Reads. getArbiterApplication folds expiry into the answer — otherwise an
        // application would look alive forever (an event on expiry is deliberately not
        // provided: there is no transaction that would send it).
        sels[4]  = ArbiterApplicationsFacet.getArbiterApplication.selector;
        sels[5]  = ArbiterApplicationsFacet.getApplicationWindow.selector;
        sels[6]  = ArbiterApplicationsFacet.getApplicationRequirements.selector;
        sels[7]  = ArbiterApplicationsFacet.isManualAdmissionOpen.selector;
        sels[8]  = ArbiterApplicationsFacet.getApplicants.selector;
        sels[9]  = ArbiterApplicationsFacet.getApplicantCount.selector;
        sels[10] = ArbiterApplicationsFacet.getApplicantsPage.selector;
    }

    // DealMetadataFacet — 1 selector
    function dealMetadataFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = DealMetadataFacet.getDealTokenURI.selector;
    }

    // JobReceiptFacet — 21 selectors (ERC-721 + receipt)
    function jobReceiptFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](21);
        sels[0]  = JobReceiptFacet.name.selector;
        sels[1]  = JobReceiptFacet.symbol.selector;
        sels[2]  = JobReceiptFacet.balanceOf.selector;
        sels[3]  = JobReceiptFacet.ownerOf.selector;
        sels[4]  = JobReceiptFacet.tokenURI.selector;
        sels[5]  = JobReceiptFacet.transferFrom.selector;
        sels[6]  = bytes4(0x42842e0e); // safeTransferFrom(address,address,uint256) — overload, .selector ambiguous
        sels[7]  = bytes4(0xb88d4fde); // safeTransferFrom(address,address,uint256,bytes) — overload, .selector ambiguous
        sels[8]  = JobReceiptFacet.approve.selector;
        sels[9]  = JobReceiptFacet.setApprovalForAll.selector;
        sels[10] = JobReceiptFacet.getApproved.selector;
        sels[11] = JobReceiptFacet.isApprovedForAll.selector;
        sels[12] = JobReceiptFacet.mintJobReceipt.selector;
        sels[13] = JobReceiptFacet.burnJobReceipt.selector;
        sels[14] = JobReceiptFacet.setSvgRenderer.selector;
        sels[15] = JobReceiptFacet.getSvgRenderer.selector;
        sels[16] = JobReceiptFacet.getJobReceiptData.selector;
        sels[17] = JobReceiptFacet.isJobReceiptToken.selector;
        sels[18] = JobReceiptFacet.isJobReceiptBurned.selector;
        sels[19] = JobReceiptFacet.getTokenIdByJobId.selector;
        sels[20] = JobReceiptFacet.getReceiptTotalSupply.selector;
    }

    // ReputationFacet — 9 selectors (getUnresolvedDisputes — a counter of disputes
    // that ended without a verdict)
    function reputationFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](9);
        sels[0] = ReputationFacet.autoAwardXP.selector;
        sels[1] = ReputationFacet.claimXP.selector;
        sels[2] = ReputationFacet.notifyExecutorFault.selector;
        sels[3] = ReputationFacet.getXP.selector;
        sels[4] = ReputationFacet.getUniqueActiveUsers.selector;
        sels[5] = ReputationFacet.hasClaimed.selector;
        sels[6] = ReputationFacet.isDealWin.selector;
        sels[7] = ReputationFacet.getCleanStreak.selector;
        sels[8] = ReputationFacet.getUnresolvedDisputes.selector;
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory sels)
        internal pure returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({ facetAddress: facet, action: action, functionSelectors: sels });
    }
}
