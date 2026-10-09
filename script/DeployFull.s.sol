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
// the DAO is active (a deliberate decision: no hand-picked ones),
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
// Then 250, on 18 September 2026, "AN ARBITER IS NOT A PLAYER IN THE MARKET"
// (the owner's decision of 17 September). Four selectors, and not one of them is
// the rule itself — the rule is two internal checks that no selector can show:
// RegistryFacet gained getOpenDealCount (+1, 15 against the previous 14) and
// JobBoardFacet gained getOpenMarketItems, pruneClosedApplications and
// getAppliedJobIds (+3, 16 against 13). The count went 246 -> 250 and the facet
// count did not move. What DID change without a selector to show it: five
// counters and one index appended to three storage namespaces, and the doors of
// both boards, the factory and the two arbiter facets now refuse by name. The
// selectors that carry the rule (mintJob, applyForJob, addArbiter, ...) are all
// already mounted, so on chain this is a Replace of five facets plus an Add of
// these four — the composition is in script/UpgradeArbiterNotAParty.s.sol, and
// the back-fill it must carry is script/MarketPresenceBackfill.sol.
//
// Then 256, on 18 September 2026, for the three decisions of that day. Six
// selectors, and again the rules themselves are mostly invisible:
//   * the movable appeal quorum — ArbiterRegistryFacet gained getAppealPanel
//     (+1). The rule is `min(3, eligible)` inside raiseAppeal and one number
//     frozen per appeal; no selector shows it.
//   * item D1, a dead dispute claim — ArbiterRegistryFacet gained abandonClaim
//     (+1, 33 against the previous 31 with getAppealPanel).
//   * a direct hire as an OFFER — RegistryFacet gained registerOffer,
//     notifyOfferAccepted, syncOfferAcceptance and isOfferPending (+4, 19
//     against 15).
// 250 -> 256, the facet count unchanged. ⚠️ UNLIKE the 17 September rule, this
// one is NOT diamond-only: `declineOffer` and the activation announcement live
// in Agreement, so the cut needs a new implementation and a new deployer, and
// the deals that already exist keep the old behaviour for ever (EIP-1167).
//
// Then 253, on 22 September 2026, THREE DOORS INTO THE CORPS BECOME TWO (the
// owner's decision). ArbiterApplicationsFacet LOSES three selectors —
// applyForArbiterSeat, approveArbiterApplication, rejectArbiterApplication (16
// against the previous 13 here; on chain those three are already mounted and
// have to come off with `Remove`). The application asked exactly what the
// self-service door asks and added only a person's right to refuse somebody
// the rules already admit; the self-service door itself stopped waiting for
// governance in the same change, so the ladder now ends in a seat. `addArbiter`
// keeps its selector and loses the chief: it is the owner's alone, because it
// is the one entrance that measures nothing at all.
// 256 -> 253, the facet count unchanged.
//
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
//                        other than by a timeout refunding the client 100%.
//                        Since 22 September 2026 `applyAsArbiter` no longer
//                        waits for governance, but it asks for a run of five
//                        clean deals, and a fresh deployment has no deals at
//                        all; `addArbiter` is the owner's.
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
import "../src/facets/TreasuryLinkFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../src/SVGRenderer.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";

contract DeployFull is Script {

    // ── The treasury numbers a fresh diamond starts with ─────────────────────
    // The same four script/UpgradeTreasuryLink.s.sol carried into the live
    // diamond on 4 September 2026, and the same four that diamond reads back
    // today (measured 14 September 2026 against 0x760f0736: 1000 / 2000 / 5000
    // / 50). They are written out here rather than imported from the upgrade
    // script so that a fresh deployment and an upgrade cannot drift into
    // disagreeing about them without one of the two files changing visibly.
    uint256 constant TREASURY_VAULT_BPS      = 1000; // arbiter vault's share
    uint256 constant TREASURY_PAYROLL_BPS    = 2000; // arbiter payroll stream
    uint256 constant TREASURY_FOUNDATION_BPS = 5000; // foundation
    uint256 constant VAULT_TARGET_DISPUTES   = 50;   // vault target, in disputes

    function run() external {
        address usdc             = vm.envOr("USDC_ADDRESS",      address(0x036CbD53842c5426634e7929541eC2318f3dCF7e));
        address feeRecipient     = vm.envOr("FEE_RECIPIENT",     address(0));
        address trustedForwarder = vm.envOr("TRUSTED_FORWARDER", address(0));
        address initialArbiter   = vm.envOr("INITIAL_ARBITER",   address(0));
        // The address every deployed contract is handed to as its owner. It is the
        // signer named on the command line (--account / --private-key / --sender),
        // not a key read out of the environment. Foundry refuses to broadcast from
        // DEFAULT_SENDER, so a live run can never bake the placeholder in.
        address owner            = msg.sender;

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

        vm.startBroadcast();

        // ── 1. Deploy every implementation ───────────────────────────────────
        DiamondCutFacet        cutFacet     = new DiamondCutFacet();
        DiamondLoupeFacet      loupeFacet   = new DiamondLoupeFacet();
        OwnershipFacet         ownFacet     = new OwnershipFacet();
        RegistryFacet          regFacet     = new RegistryFacet();
        FactoryFacet           facFacet     = new FactoryFacet();
        JobBoardFacet          jobBoard     = new JobBoardFacet();
        ServiceBoardFacet      serviceBoard = new ServiceBoardFacet();
        ArbiterRegistryFacet   arbiterFacet = new ArbiterRegistryFacet();
        ArbiterVaultFacet      vaultFacet   = new ArbiterVaultFacet();
        ArbiterAccountabilityFacet accFacet = new ArbiterAccountabilityFacet();
        ArbiterApplicationsFacet appFacet = new ArbiterApplicationsFacet();
        TreasuryLinkFacet      treasuryLink = new TreasuryLinkFacet();
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
        console.log("ArbiterVaultFacet:    ", address(vaultFacet));
        console.log("ArbiterAccountabilityFacet:", address(accFacet));
        console.log("ArbiterApplicationsFacet:", address(appFacet));
        console.log("TreasuryLinkFacet:    ", address(treasuryLink));
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
        // ⚠️ The certificate's draughtsman has to exist BEFORE the
        // implementation that points at it: the address is a constant of
        // Agreement's code, and a clone cannot be re-pointed afterwards.
        require(
            AGREEMENT_RENDERER.code.length > 0,
            "DeployFull: no certificate renderer on this chain - run script/DeployAgreementRenderer.s.sol first"
        );
        Agreement          agreementImpl = new Agreement();
        console.log("Agreement impl:       ", address(agreementImpl));
        console.log("Certificate renderer: ", AGREEMENT_RENDERER);

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
        //        ArbiterAccountability, ArbiterApplications, TreasuryLink,
        //        JobReceiptFacet, ReputationFacet
        IDiamondCut.FacetCut[] memory cuts2 = buildRemainingCuts(
            address(jobBoard),
            address(serviceBoard),
            address(arbiterFacet),
            address(vaultFacet),
            address(accFacet),
            address(appFacet),
            address(treasuryLink),
            address(receiptFacet),
            address(repFacet)
        );

        IDiamondCut(address(diamond)).diamondCut(cuts2, address(0), "");

        // ── 6. The treasury numbers ───────────────────────────────────────────
        // ⚠️ MOUNTING TreasuryLinkFacet IS NOT ENOUGH. Its four numbers live in
        // ArbiterRegistryStorage, and a freshly cut diamond has them all at
        // zero — which is a legitimate-looking answer to every one of its
        // getters, not a revert. Zero shares means the treasury ladder routes
        // nothing to the arbiter vault or the payroll stream, and a zero vault
        // target makes the treasury skip the vault rung entirely. Silent, and
        // indistinguishable from a deliberate policy.
        //
        // The upgrade path (script/UpgradeTreasuryLink.s.sol) carries these as
        // the cut's `_init` because an upgrade has no other moment that is
        // atomic with the mount. A fresh deployment does: it owns the whole
        // sequence and is the owner, so it sets them directly and then reads
        // them back below.
        TreasuryLinkFacet(address(diamond)).setTreasuryShares(
            TREASURY_VAULT_BPS, TREASURY_PAYROLL_BPS, TREASURY_FOUNDATION_BPS
        );
        TreasuryLinkFacet(address(diamond)).setVaultTargetDisputes(VAULT_TARGET_DISPUTES);

        // ── 7. Link the SVGRenderer ───────────────────────────────────────────
        JobReceiptFacet(address(diamond)).setSvgRenderer(address(svgRenderer));

        // ── 8. The first arbiter ──────────────────────────────────────────────
        // Without this, a round of disputes cannot be closed other than by a timeout
        // refunding the client (see the note at require(initialArbiter != address(0))
        // above). chiefArbiter is NOT set — on a live diamond it stays zero.
        ArbiterRegistryFacet(address(diamond)).addArbiter(initialArbiter);

        vm.stopBroadcast();

        // ── 9. The result ─────────────────────────────────────────────────────
        uint256 feeBps = FactoryFacet(address(diamond)).getFeeBps();
        uint256 feeFloor = FactoryFacet(address(diamond)).getFeeFloor();

        // Read back through the diamond — step 6 wrote them, and a write that
        // did not land would otherwise show up first on a live fee split.
        require(
            TreasuryLinkFacet(address(diamond)).getTreasuryVaultBps() == TREASURY_VAULT_BPS
                && TreasuryLinkFacet(address(diamond)).getTreasuryPayrollBps() == TREASURY_PAYROLL_BPS
                && TreasuryLinkFacet(address(diamond)).getTreasuryFoundationBps() == TREASURY_FOUNDATION_BPS,
            "DeployFull: the treasury shares do not read back as the ones set - the link is mounted but blind"
        );
        require(
            TreasuryLinkFacet(address(diamond)).getVaultTargetDisputes() == VAULT_TARGET_DISPUTES,
            "DeployFull: the vault target does not read back - the treasury would skip the vault rung"
        );
        address[] memory arbiters = ArbiterVaultFacet(address(diamond)).getArbiters();

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
        address arbiterVaultFacetAddr,
        address accountabilityFacetAddr,
        address applicationsFacetAddr,
        address treasuryLinkFacetAddr,
        address receiptFacetAddr,
        address reputationFacetAddr
    ) public pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](9);
        cuts[0] = _cut(jobBoardAddr,             IDiamondCut.FacetCutAction.Add, jobBoardFacetSelectors());
        cuts[1] = _cut(serviceBoardAddr,         IDiamondCut.FacetCutAction.Add, serviceBoardFacetSelectors());
        cuts[2] = _cut(arbiterFacetAddr,         IDiamondCut.FacetCutAction.Add, arbiterRegistryFacetSelectors());
        cuts[3] = _cut(accountabilityFacetAddr,  IDiamondCut.FacetCutAction.Add, arbiterAccountabilityFacetSelectors());
        cuts[4] = _cut(applicationsFacetAddr,    IDiamondCut.FacetCutAction.Add, arbiterApplicationsFacetSelectors());
        cuts[5] = _cut(treasuryLinkFacetAddr,    IDiamondCut.FacetCutAction.Add, treasuryLinkFacetSelectors());
        cuts[6] = _cut(receiptFacetAddr,         IDiamondCut.FacetCutAction.Add, jobReceiptFacetSelectors());
        cuts[7] = _cut(reputationFacetAddr,      IDiamondCut.FacetCutAction.Add, reputationFacetSelectors());
        // The money and the plain reads (16 September 2026). A group of its own
        // because a FacetCut element carries exactly ONE address.
        cuts[8] = _cut(arbiterVaultFacetAddr,    IDiamondCut.FacetCutAction.Add, arbiterVaultFacetSelectors());
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

    // RegistryFacet — count by the `new bytes4[](n)` literal below. 14 -> 15 on
    // 18 September 2026 (getOpenDealCount, the unfinished-deal count the doors
    // into the arbiter corps read — "an arbiter is not a player in the
    // market"), and 15 -> 19 the same day, when a direct hire became an OFFER:
    // registerOffer (the road that names an executor who has not agreed),
    // notifyOfferAccepted (the clone's announcement that he has),
    // syncOfferAcceptance (anybody's repair for a lost announcement) and
    // isOfferPending (the read).
    function registryFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](20);
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
        sels[13] = RegistryFacet.notifyWorkHandedIn.selector;
        sels[14] = RegistryFacet.getOpenDealCount.selector;
        sels[15] = RegistryFacet.registerOffer.selector;
        sels[16] = RegistryFacet.notifyOfferAccepted.selector;
        sels[17] = RegistryFacet.syncOfferAcceptance.selector;
        sels[18] = RegistryFacet.isOfferPending.selector;
        // The market's own pulse, appended 20 September 2026: the O(1) twin of
        // getActive().length + getDisputed().length, and the first of the two
        // terms of the handover's liveness condition.
        sels[19] = RegistryFacet.getLiveDeals.selector;
    }

    // FactoryFacet — 28 selectors (setPaused/isPaused/getProtocolArbiter/
    // setProtocolArbiter/getArbitrationThreshold/setArbitrationThreshold were deleted
    // and are no longer in the ABI; 21 -> 23 on 25 August 2026:
    // getUndeliveredFees/withdrawUndeliveredFees — a fee the recipient would not take
    // is now a debt to the protocol rather than a person's locked refund;
    // 23 -> 27 on 3 September 2026: the emergency brake, decision 17;
    // 27 -> 28 on 3 September 2026: MAX_FEE_BPS, the fee ceiling that used to be
    // a bare literal written twice — item 138)
    function factoryFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](28);
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
        // The emergency brake (decision 17), 3 September 2026. A diamond
        // deployed from scratch has to carry it: the boards' `whenNotPaused`
        // reads the brake's clock now, and a fresh deployment that mounted the
        // readers without the writer would ship the exact ornament this cut
        // exists to remove — a guard on nine money doors that nothing can arm.
        // Mounted on the live diamond by script/UpgradeEmergencyBrake.s.sol.
        sels[23] = FactoryFacet.pauseNewDeals.selector;
        sels[24] = FactoryFacet.resumeNewDeals.selector;
        sels[25] = FactoryFacet.newDealsPausedUntil.selector;
        // A public constant's getter has no `.selector` on the contract type —
        // Solidity exposes that only for functions — so it is spelled out.
        sels[26] = bytes4(keccak256("NEW_DEALS_PAUSE_DURATION()"));
        // The fee ceiling (item 138), 3 September 2026. Named rather than left
        // as the bare `2_000` that stood in `initFeeModel` and `setFeeBps`, and
        // mounted rather than kept internal: the admin screen that refuses a
        // rate above the ceiling keeps its own copy of "20%" today, and a copy
        // is what goes stale on the next cut. Same spelling-out as the line
        // above, and for the same reason.
        sels[27] = bytes4(keccak256("MAX_FEE_BPS()"));
    }

    // JobBoardFacet — 16 selectors (13 -> 16 on 18 September 2026, "an arbiter
    // is not a player in the market": getOpenMarketItems — the six numbers a
    // screen shows instead of a bare refusal; pruneClosedApplications — the
    // bound on the one count that is a scan; getAppliedJobIds — the index that
    // scan reads)
    function jobBoardFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](16);
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
        sels[13] = JobBoardFacet.getOpenMarketItems.selector;
        sels[14] = JobBoardFacet.pruneClosedApplications.selector;
        sels[15] = JobBoardFacet.getAppliedJobIds.selector;
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

    // ArbiterRegistryFacet — count by the `new bytes4[](n)` literal below, not by
    // this line. 59 → 31 on 16 September 2026: twenty-eight selectors moved to
    // ArbiterVaultFacet (the EIP-170 split — the facet stood 44 bytes under the
    // ceiling). NOT ONE SIGNATURE CHANGED, so the diamond's total is the same
    // before and after; only the address behind those twenty-eight moved.
    //
    // 33 → 30 on 9 October 2026: three signatures DID go, and the diamond's total
    // went with them (267 → 264). See the note inside.
    function arbiterRegistryFacetSelectors() public pure returns (bytes4[] memory sels) {
        // 33 → 30 ON 9 OCTOBER 2026: the governance hand over a verdict is gone.
        // `overturnVerdict(address,bool)` 0x42a71c6c, `freezeVerdict(address)`
        // 0x5533316c and `unfreezeVerdict(address)` 0x69315118 left
        // ArbiterRegistryFacet that morning, and the `Remove` group of
        // script/UpgradeOctoberBatch.s.sol took the same three off the diamond at
        // block 47 872 983. Measured at block 47 873 768: fourteen facets, 264
        // routed, `facetAddress` the zero address for all three, the arbiter
        // registry holding thirty at
        // 0x11DC81C6dFdB383EDadaFF166032DbB735371262.
        //
        // ⚠️ THE RULE IS: THIS LIST FOLLOWS THE CHAIN, NOT THE COMPILED FACET, and
        // for the hours between the deletion and the cut the two disagreed. The
        // three were held here by their bytes the whole time, because dropping
        // them first was tried and measured: 161 tests stopped existing, seven
        // `*Upgrade` stands collapsing to one synthetic failure each (nine, on the
        // measurement of 9 October), because they build their diamond from THIS
        // function and then replay a signed cut
        // whose `Replace` group names one of the three — and `Replace` reverts on
        // a selector the diamond does not route, taking the whole cut and the
        // stand's `setUp` with it. ⚠️ THE SUITE COUNT DID NOT MOVE THROUGH ANY OF
        // IT; only the test count showed anything at all.
        //
        // NINE stands, measured rather than the seven this note first guessed, now
        // state the shape they need instead of inheriting it: each mounts the three
        // itself, out of its OWN census, through the shared
        // `ArbiterSplitRig._mountRemovedVerdictHandDoors`. Those censuses are older
        // than the cut and route all three for ever, which is why that is a permanent
        // reconciliation and not an allowance waiting to be deleted.
        sels = new bytes4[](30);

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
        // The public door for a claim its arbiter let run out (item D1,
        // 18 September 2026). It sits beside the two doors above because it is
        // the third answer to "who ends a claim": its owner inside the window,
        // the deal on a finalized verdict, and — past the window — anybody.
        sels[28] = ArbiterRegistryFacet.abandonClaim.selector;

        // The verdict
        sels[9] = ArbiterRegistryFacet.submitVerdict.selector;
        sels[10] = ArbiterRegistryFacet.finalizeVerdict.selector;
        sels[11] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        sels[12] = ArbiterRegistryFacet.clearStuckVerdict.selector;

        // The appeal
        sels[13] = ArbiterRegistryFacet.raiseAppeal.selector;
        sels[14] = ArbiterRegistryFacet.voteOnAppeal.selector;
        sels[15] = ArbiterRegistryFacet.resolveAppeal.selector;

        // Handing over the DAO address in two steps (26 August 2026): this is the
        // PROPOSAL, and the rights pass only when the named address sends
        // acceptDAOAddress() itself. The two READS of that handover
        // (getDAOAddress, getPendingDAOAddress) moved to ArbiterVaultFacet.
        sels[16] = ArbiterRegistryFacet.setDAOAddress.selector;
        sels[17] = ArbiterRegistryFacet.acceptDAOAddress.selector;

        // The three CONSTANT getters that did not move with the rest of the reads,
        // and that is not an oversight: each reads a private constant that this
        // facet still applies (activateDAO, applyAsArbiter, _recordArbiterMistake,
        // recordNoResponse, claimDispute). Moving them would mean a second
        // declaration of the number next door — the outside answered by a mirror
        // while the live rule applies the original. Same reasoning as the
        // 16 August split, same five constants, written out in the VIEWS header of
        // the facet itself.
        sels[18] = ArbiterRegistryFacet.isDaoActive.selector;
        sels[19] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        sels[20] = ArbiterRegistryFacet.getDaoThreshold.selector;
        sels[21] = ArbiterRegistryFacet.getMaxArbiterMistakes.selector;
        sels[22] = ArbiterRegistryFacet.getNoResponseFloor.selector;
        sels[23] = ArbiterRegistryFacet.getMaxClaimsPerArbiter.selector;

        // getChiefBloc calls the private _chiefBloc that addArbiter holds; moving
        // it would cost a second copy of the body.
        sels[24] = ArbiterRegistryFacet.getChiefBloc.selector;

        // The arbiter's chat keys (9 August 2026) — the WRITE. The reads live in
        // ArbiterAccountabilityFacet.
        sels[25] = ArbiterRegistryFacet.setArbiterChatKey.selector;

        // The record "asked, got no answer" and the presentation digest
        // (14 August 2026) — again only the WRITES; five readers of the group moved
        // to ArbiterAccountabilityFacet on 16 August 2026.
        sels[26] = ArbiterRegistryFacet.recordNoResponse.selector;
        sels[27] = ArbiterRegistryFacet.recordPresentationDigest.selector;

        // What an appeal needs from the corps: eligible, required, cast
        // (18 September 2026). It stays in this facet rather than moving to the
        // reads in ArbiterVaultFacet because it shares the private eligibility
        // count with raiseAppeal, and a second copy of that count is exactly
        // the mirror this rule must not have.
        sels[29] = ArbiterRegistryFacet.getAppealPanel.selector;
    }

    // ArbiterVaultFacet — count by the `new bytes4[](n)` literal below.
    //
    // The twenty-eight selectors carved out of ArbiterRegistryFacet on
    // 16 September 2026, plus six the appeal economics added on 17 September
    // 2026 (the panel's pull, the bank's payment of appeal debts, and four
    // reads). The line is one sentence: THE REGISTRY KEEPS EVERY DOOR
    // THAT DECIDES A DISPUTE OR CHANGES WHO IS AN ARBITER; THIS FACET TAKES EVERY
    // DOOR THAT ONLY MOVES MONEY AND EVERY DOOR THAT ONLY READS A NUMBER.
    //
    // ⚠️ EVERY SIGNATURE IS UNCHANGED, and that is the point: a selector is
    // derived from the signature, so `ArbiterVaultFacet.fundVault.selector` and
    // the `ArbiterRegistryFacet.fundVault.selector` of every historical script in
    // this folder are the same four bytes. The frontend, the relayer and the
    // subgraph see no difference at all — a facet is a row in the proxy's routing
    // table, not an endpoint.
    function arbiterVaultFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](37);

        // Rewards
        sels[0] = ArbiterVaultFacet.withdrawArbiterReward.selector;
        sels[1] = ArbiterVaultFacet.fundVault.selector;
        sels[2] = ArbiterVaultFacet.setRewardPerDispute.selector;

        // The dispute fee (3% of the disputed amount, computed by Agreement) — split 80/20 arbiter/treasury
        sels[3] = ArbiterVaultFacet.creditDisputeFee.selector;
        sels[4] = ArbiterVaultFacet.withdrawTreasurySlice.selector;
        sels[5] = ArbiterVaultFacet.getTreasurySlice.selector;

        // The paid arbiter call: the floor and the quote for the top-up to it
        sels[6] = ArbiterVaultFacet.setArbiterFloor.selector;
        sels[7] = ArbiterVaultFacet.getArbiterFloor.selector;
        sels[8] = ArbiterVaultFacet.quoteDisputeTopUp.selector;

        // The paid arbiter call: payment and the soft refund of the top-up
        sels[9]  = ArbiterVaultFacet.fundDispute.selector;
        sels[10] = ArbiterVaultFacet.getDisputeBounty.selector;
        sels[11] = ArbiterVaultFacet.withdrawDisputeBounty.selector;
        sels[12] = ArbiterVaultFacet.getRefundableBounty.selector;

        // The arbiter vault's discount on the dispute top-up (29 August 2026)
        sels[13] = ArbiterVaultFacet.setDisputeDiscount.selector;
        sels[14] = ArbiterVaultFacet.getDisputeDiscount.selector;

        // Money read back
        sels[15] = ArbiterVaultFacet.getVaultBalance.selector;
        sels[16] = ArbiterVaultFacet.getRewardPerDispute.selector;

        // The plain state reads. Not one of them applies a rule; every one of them
        // returns a field of ArbiterRegistryStorage as it stands.
        sels[17] = ArbiterVaultFacet.getChiefArbiter.selector;
        sels[18] = ArbiterVaultFacet.isRegisteredArbiter.selector;
        sels[19] = ArbiterVaultFacet.getArbiters.selector;
        sels[20] = ArbiterVaultFacet.getDisputeClaimer.selector;
        sels[21] = ArbiterVaultFacet.getClaimCommitment.selector;
        sels[22] = ArbiterVaultFacet.getPendingVerdict.selector;
        sels[23] = ArbiterVaultFacet.hasSubmittedVerdict.selector;
        sels[24] = ArbiterVaultFacet.getAppealVotes.selector;
        sels[25] = ArbiterVaultFacet.hasVotedOnAppeal.selector;
        sels[26] = ArbiterVaultFacet.getDAOAddress.selector;
        sels[27] = ArbiterVaultFacet.getPendingDAOAddress.selector;

        // The appeal economics (17 September 2026): the panel's pull, its read,
        // the settled appeal's ledger, and the price of an appeal before it is raised
        sels[28] = ArbiterVaultFacet.withdrawAppealShare.selector;
        sels[29] = ArbiterVaultFacet.getAppealShareOwed.selector;
        sels[30] = ArbiterVaultFacet.getAppealLedger.selector;
        sels[31] = ArbiterVaultFacet.quoteAppealDeposit.selector;
        // The bank's way out for appeal debts, and their read (second pass, same day)
        sels[32] = ArbiterVaultFacet.settleAppealDebts.selector;
        sels[33] = ArbiterVaultFacet.getAppealDebts.selector;
        // The bond a CASE carries (22 September 2026): the arbiter's way to
        // collect it when the deal ended without his verdict, and the two reads
        // a screen needs to know whether to offer the button and whether his
        // one slot is free.
        sels[34] = ArbiterVaultFacet.withdrawCaseBond.selector;
        sels[35] = ArbiterVaultFacet.getCaseBond.selector;
        sels[36] = ArbiterVaultFacet.getJudgingCount.selector;
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
        sels = new bytes4[](38);
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
        // The handover's SECOND condition, appended 20 September 2026, and the
        // whole of it: every term with its floor and a verdict, out of the same
        // HandoverLib.readiness() that activateDAO() calls. It reads across
        // three namespaces rather than this facet's constants, which is why it
        // is not grouped with the three above it.
        sels[36] = ArbiterAccountabilityFacet.getHandoverReadiness.selector;

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

        // ── The overturn SHARE, and the rule the chain judges it by
        //    (21 September 2026) ──
        // NOT YET ON CHAIN — it is listed in the pending-cut literal of
        // test/DeployFullMatchesChain.t.sol, and the day the cut is signed that
        // line goes and the census is re-read.
        //
        // It carries the three rule numbers out with the record on purpose: the
        // web client decides from them whether a rate may be shown at all, and a
        // copy of that floor on the screen would be a second threshold nothing
        // compares against the one the chain suspends on.
        sels[37] = ArbiterAccountabilityFacet.getArbiterOutcomeRecord.selector;
    }

    // ArbiterApplicationsFacet — 13 selectors (22 September 2026).
    //
    // The thirteenth facet, and what is left of it. It was built as the interim
    // door into the arbiter corps: `applyAsArbiter` refused `DAONotActive` on
    // its first line, so before governance nobody could put himself forward by
    // any means and the only entrance was the owner's hand.
    //
    // ⚠️ THAT PREMISE WAS REMOVED ON 22 SEPTEMBER 2026, and three selectors
    // went with it — `applyForArbiterSeat`, `approveArbiterApplication`,
    // `rejectArbiterApplication`. The self-service door is open now and asks a
    // run of five clean deals; the application asked exactly the same thing and
    // added only a person's right to refuse somebody the rules already admit.
    //
    // ⚠️ WHAT THIS LIST IS AND IS NOT. It is what a FRESH deployment mounts.
    // The live diamond still carries the three removed selectors until a cut
    // takes them off with `Remove`, and that cut must keep them in a group of
    // their own: `Replace` reverts on an unmounted selector and `Add` on a
    // mounted one, and either mistake drops the whole cut in one transaction.
    //
    // Why a separate facet rather than an addition to one of the two neighbours
    // — see the header of src/facets/ArbiterApplicationsFacet.sol: the registry
    // stands under a thousand bytes clear of the EIP-170 ceiling.
    function arbiterApplicationsFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](13);

        // The applicant's own door out. Gasless (ERC-2771), like everything on
        // the applicant's side of this facet.
        //
        // ⚠️ IT OUTLIVED THE DOOR IN. Nothing can become Pending any more, so
        // this can only ever clear a record filed before the removal — of which
        // the live chain has none (`getApplicantCount()` reads 0, measured
        // 22 September 2026). It is mounted because taking a man's ability to
        // clear his own record away is a decision to be taken out loud.
        sels[0] = ArbiterApplicationsFacet.withdrawArbiterApplication.selector;

        // Reads. getArbiterApplication folds expiry into the answer — otherwise an
        // application would look alive forever (an event on expiry is deliberately not
        // provided: there is no transaction that would send it).
        sels[1] = ArbiterApplicationsFacet.getArbiterApplication.selector;
        sels[2] = ArbiterApplicationsFacet.getApplicationWindow.selector;
        sels[3] = ArbiterApplicationsFacet.getApplicationRequirements.selector;
        sels[4] = ArbiterApplicationsFacet.isManualAdmissionOpen.selector;
        sels[5] = ArbiterApplicationsFacet.getApplicants.selector;
        sels[6] = ArbiterApplicationsFacet.getApplicantCount.selector;
        sels[7] = ArbiterApplicationsFacet.getApplicantsPage.selector;

        // The two retired bond doors. Both answer `SeatBondRetired`, and they are
        // MOUNTED on purpose: a removed selector answers a pressed button with a
        // bare failure and no name, this answers with one a screen can read out.
        // They come off when the screens that press them do.
        sels[8]  = ArbiterApplicationsFacet.postArbiterBond.selector;
        sels[9]  = ArbiterApplicationsFacet.postArbiterBondWithPermit.selector;
        sels[10] = ArbiterApplicationsFacet.isArbiterActive.selector;

        // Taking back a granted seat that nothing has been earned in
        // (11 September 2026). Administrative, raw msg.sender, and retired by the
        // DAO ratchet — after the handover arbiters seat themselves and removal
        // belongs to the successor.
        //
        // ⚠️ It is NOT a second removal door. It refuses every arbiter with a
        // record, so the procedure — proposal, 48-hour pause, right of reply —
        // still owns everyone it owned before.
        //
        // No companion read is mounted on purpose: a form decides whether to
        // show the button by simulating THIS call and reading the named error it
        // refuses with. A second function answering "may I" would be a second
        // copy of the rule, and the copy that drifted would be the one saying
        // yes.
        sels[11] = ArbiterApplicationsFacet.revokeUnprovenSeat.selector;

        // Where a seat's bond stands. Since 22 September 2026 it answers NONE or
        // UNPOSTED and nothing else, and it stays mounted because every live
        // Agreement clone calls this selector and a clone is pinned to its
        // implementation for life.
        sels[12] = ArbiterApplicationsFacet.getBondState.selector;
    }

    // TreasuryLinkFacet — count by the `new bytes4[](n)` literal below (9 until
    // 24 September 2026, when the arbiter bank's surplus door and its quote
    // arrived: 11).
    //
    // ⚠️ THIS REPLACED DealMetadataFacet HERE ON 14 SEPTEMBER 2026, and the two
    // moves are one correction, not two. Measured against the live diamond
    // 0x760f0736 that day, the set this script mounts and the set the chain
    // routes differed by exactly ten selectors, nine one way and one the other:
    // the chain had all nine of TreasuryLinkFacet (cut in 4 September, never
    // back-ported here), and this script had `getDealTokenURI`, whose facet the
    // owner unmounted that morning. Fixing only the dead one would have left a
    // fresh deployment with no treasury link at all — a diamond where the fee
    // split, the arbiter vault and the payroll stream answer nothing.
    function treasuryLinkFacetSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](16);
        sels[0] = TreasuryLinkFacet.fundArbiterPayroll.selector;
        sels[1] = TreasuryLinkFacet.getArbiterPayrollBalance.selector;
        sels[2] = TreasuryLinkFacet.getVaultTarget.selector;
        sels[3] = TreasuryLinkFacet.getVaultTargetDisputes.selector;
        sels[4] = TreasuryLinkFacet.getTreasuryVaultBps.selector;
        sels[5] = TreasuryLinkFacet.getTreasuryPayrollBps.selector;
        sels[6] = TreasuryLinkFacet.getTreasuryFoundationBps.selector;
        sels[7] = TreasuryLinkFacet.setTreasuryShares.selector;
        sels[8] = TreasuryLinkFacet.setVaultTargetDisputes.selector;
        // The arbiter bank's door out and its quote (24 September 2026, mainnet
        // item D2). The bank used to have one way out — a three-dollar discount
        // on a top-up in a small dispute — and that way waits on an event which
        // may never happen. This is the door: open to anybody, the recipient read
        // off the treasury, whatever stands above the target going to the
        // foundation the treasury already pays.
        sels[9]  = TreasuryLinkFacet.pushVaultSurplus.selector;
        sels[10] = TreasuryLinkFacet.getVaultSurplus.selector;
        // The payroll pot's door out (25 September 2026, mainnet item D3). The
        // pot had taken a fifth of every distribution since 4 September and had
        // no outlet of any kind. These five are the outlet: a period's pot
        // divided by the cases that stood in it, booked per arbiter by anybody,
        // the unclaimed remainder pushed to the foundation once the claim window
        // lapses, and three reads a screen or a keeper needs.
        sels[11] = TreasuryLinkFacet.bookPayrollShare.selector;
        sels[12] = TreasuryLinkFacet.sweepPayrollPeriod.selector;
        sels[13] = TreasuryLinkFacet.quotePayrollShare.selector;
        sels[14] = TreasuryLinkFacet.getPayrollPeriod.selector;
        sels[15] = TreasuryLinkFacet.getPayrollPeriodStatus.selector;
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
        sels = new bytes4[](10);
        sels[0] = ReputationFacet.autoAwardXP.selector;
        sels[1] = ReputationFacet.claimXP.selector;
        sels[2] = ReputationFacet.notifyExecutorFault.selector;
        sels[3] = ReputationFacet.getXP.selector;
        sels[4] = ReputationFacet.getUniqueActiveUsers.selector;
        sels[5] = ReputationFacet.hasClaimed.selector;
        sels[6] = ReputationFacet.isDealWin.selector;
        sels[7] = ReputationFacet.getCleanStreak.selector;
        sels[8] = ReputationFacet.getUnresolvedDisputes.selector;
        // 20 September 2026. NOT YET ON CHAIN — it is listed in the pending-cut
        // literal of test/DeployFullMatchesChain.t.sol, and the day the cut is
        // signed that line goes and the census is re-read.
        sels[9] = ReputationFacet.getStreakStanding.selector;
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory sels)
        internal pure returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({ facetAddress: facet, action: action, functionSelectors: sels });
    }
}
