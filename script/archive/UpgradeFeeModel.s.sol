// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeFeeModel.s.sol
//
// Moves the LIVE diamond 0x760F07367888C62f7c2Dfb619A5e534132855ce5 from a fixed
// per-region fee onto max(amount * feeBps / 10_000, feeFloor).
//
// ── THE BASELINE IS THE CHAIN, NOT THE BRANCH. ───────────────────────────
// The live diamond was assembled by script/DeployFull.s.sol on 25.07.2026
// (broadcast/DeployFull.s.sol/84532/run-latest.json, ts 1784994655863) and has been
// patched pointwise THREE times since — confirmed by real (non dry-run)
// broadcast/*/84532/run-latest.json files with later timestamps:
//
//   - UpgradeAgreementDeployerV5.s.sol (27.07, ts 1785153774304) — switched on the
//     EIP-1167 clones. The live AgreementDeployer is now
//     0x863923769fbefb5da6c4657d6f9ae7d900965b2b and NOT the
//     0x5B765CeeCA347973a33AFD5eD2d3c8a6Bde0323B from DeployFull. The
//     implementation is now 0xf7cbece7949a0f7df325fff27122840a19c14a2b (from
//     BEFORE the dispute fee reached the sources — details below).
//   - DeployTreasury.s.sol (27.07, ts 1785158208535) — Treasury
//     0x2e7a7a0515bfdc0006a812ebb3e55d32800bc660. That transaction does NOT touch
//     the diamond (setFeeRecipient is a separate manual step, outside the script).
//   - UpgradeArbiterRegistryFundVault.s.sol (27.07, ts 1785167272950) — a clean
//     Replace of 44/44 ArbiterRegistryFacet selectors (access to fundVault:
//     onlyOwner -> the owner OR the feeRecipient). The live ArbiterRegistryFacet is
//     now 0x3380e0a5b9b87cb677e19a96a76f094c511f8bc0 and NOT the
//     0xf707aa69fdcd0160dbe57e402356de2079085326 from DeployFull.
//
// Not one of those three patches touched FactoryFacet, JobBoardFacet,
// ServiceBoardFacet, RegistryFacet or DealMetadataFacet — their live address is
// still the one DeployFull deployed.
//
// The consequence for this script: it reads the CURRENT addresses and selectors
// FROM THE CHAIN through facetAddress()/facets() at the moment it runs, and
// substitutes not one of the addresses listed above as a constant. So its
// correctness does not depend on whether the diamond was patched again between the
// writing of this file and its run.
//
// ── WHAT CHANGES ─────────────────────────────────────────────────────────
// Six facets had their sources changed since the deployment commit: FactoryFacet,
// ArbiterRegistryFacet, JobBoardFacet, ServiceBoardFacet, RegistryFacet and
// DealMetadataFacet.
//
// On chain right now there are 145 selectors (11 facets); in the current sources
// those same 11 facets have 159. Remove is ZERO (not one function was deleted, read
// off by comparing facets() with methodIdentifiers directly). Add is EXACTLY 14:
//
//   FactoryFacet (8):          getFeeBps, getFeeFloor, getMaxPendingRequests,
//                              initFeeModel, quoteFee, setFeeBps, setFeeFloor,
//                              setMaxPendingRequests
//   ArbiterRegistryFacet (3):  creditDisputeFee, getTreasurySlice,
//                              withdrawTreasurySlice
//   JobBoardFacet (1):         getJobFeeHeld
//   ServiceBoardFacet (2):     getPendingRequestCount, getRequestFeeHeld
//
// RegistryFacet and DealMetadataFacet get zero Adds. Their edits do not touch the
// ABI: RegistryFacet renamed the error ZeroAddress -> RegistryZeroAddress (the same
// device as FactoryZeroAddress — a change of the ERROR SELECTOR but not of a
// function selector), and DealMetadataFacet changed the domain in the SVG from
// hexseal.com to hexseal.net. Both are a pure Replace.
//
// ── WHY ONE diamondCut AND NOT SIX ───────────────────────────────────────
// Formally, atomicity with initFeeModel is mandatory only for FactoryFacet — but
// JobBoardFacet and ServiceBoardFacet share that obligation: their
// mintJob/mintJobWithPermit and requestService/requestServiceWithPermit also call
// FactoryStorage.quote() to withhold the fee at posting time. If their Replace
// reaches the chain before FactoryFacet.initFeeModel seeds feeFloor, the very same
// FeeNotConfigured revert catches boards that are already published, merely through
// a different facet. ArbiterRegistryFacet, RegistryFacet and DealMetadataFacet do
// not depend on feeFloor at all, but there is no point splitting them into a
// separate cut for that: gas is not the constraint (an explicit decision by the
// owner), and one transaction with explicitly listed addresses is easier to check by
// eye than orchestrating the order of several.
//
// ── WHY NOT THE OLD SCRIPTS ──────────────────────────────────────────────
// script/ already holds V1-V5 of UpgradeFactoryFacet*.s.sol — all five revert, see
// the header of script/UpgradeFactoryFacetDisputeGate.s.sol. Beside them lie
// script/UpgradeArbiterRegistryDisputeFee.s.sol and
// script/UpgradeAgreementDisputeFee.s.sol — written earlier, NEVER broadcast (only
// broadcast/*/84532/dry-run/run-latest.json), doing Replace(44)+Add(3) for
// ArbiterRegistryFacet in exactly the same way as this script. Their logic is
// neither touched nor duplicated — see "THE DISPUTE FEE" below. Once THIS cut has
// gone through, UpgradeArbiterRegistryDisputeFee.s.sol will revert on its own
// pre-flight ("one of the three is already mounted") — which is expected, safe and
// not a breakage: it is simply no longer needed.
//
// ── THE SELECTOR LISTS COME FROM THE SOURCES, NOT FROM A HAND ────────────
// As in DeployFull.s.sol: each list is a `public pure` function of the form
// `<Facet>.<fn>.selector`, a single source of truth for buildFeeModelCuts() below
// and for test/UpgradeFeeModelSelectors.t.sol, which compares them against
// `out/<Facet>.sol/<Facet>.json`.methodIdentifiers.
//
// ── REPLACE AND ADD ARE SEPARATE FacetCut ENTRIES ────────────────────────
// Not one selector is in both: DiamondCutLib.replaceFunctions reverts on
// `oldFacetAddress == _facetAddress` (the same address — a Replace is meaningless),
// while DiamondCutLib.addFunctions reverts on `oldFacetAddress != address(0)` (the
// selector already exists). Both lists for each facet are checked on chain BEFORE
// the broadcast (see run() — _checkReplaceGroup/_checkAddGroup).
//
// ── THE ATOMIC SEEDING ───────────────────────────────────────────────────
// initFeeModel(bps, floor, maxPending) is called through the _init/_calldata of
// THIS SAME diamondCut. _init is the address of the FRESHLY DEPLOYED FactoryFacet
// implementation and NOT of the diamond: DiamondCutLib.initializeDiamondCut does
// `_init.delegatecall(_calldata)` while already in the diamond's context, so the
// storage resolves to the diamond's, and msg.sender through the delegatecall stays
// the owner who called diamondCut — onlyOwner here is a real gate and not
// decoration. Without it there is a window between the cut and a separate
// configuring transaction in which quote() reverts FeeNotConfigured on EVERY money
// path, including acceptApplicant/acceptRequest on already published orders. The
// specification of the call is
// test/Boards.t.sol::testInitFeeModel_SeedsConfigInTheSameTransactionAsTheCut.
// The values — 500 bps (5%), a floor of 1_000_000 (1 USDC, 6 decimals), maxPending
// 5 — are the same defaults initFactory() sets on a fresh deployment.
//
// ── THE INDEXER v2.2.0 TRAVELS WITH THIS CUT, NOT AFTER IT ───────────────
// The second dependency of this cut, besides the dispute fee below (and unlike it,
// not "as the next step" but in the same rollout window). v2.2.0 added the
// FeeCollection entity — indexing the FeeCollected event that FactoryFacet,
// JobBoardFacet and ServiceBoardFacet of this same release emit. Its deployment is
// manual.
//
// What degrades while the indexer is old: the revenue ledger is read from
// AgreementDeployed.fee, and that is a RECOMPUTATION of FactoryStorage.quote() as
// of the HIRE — not what was actually withheld:
//   - on a direct hire (deployAgreement/deployAndFund) the number matches what was
//     transferred: quote() and the transfer stand in one transaction;
//   - on the boards it diverges. acceptApplicant/acceptRequest call deployAgreement
//     from inside the diamond (msg.sender == address(this)), and there is no fee
//     transfer there at all — the real money is the jobFeeHeld/requestFeeHeld
//     withheld at POSTING. The numbers agree only if feeBps/feeFloor did not change
//     between the posting and the hire;
//   - for orders and requests published BEFORE this cut, jobFeeHeld and
//     requestFeeHeld are zero (the live facets do not write those fields at all), so
//     AgreementDeployed.fee will show a percentage that was not debited in that
//     transaction. FeeCollection, conversely, will not appear on such a hire: the
//     old fee left at posting time, taken by a facet that does not emit
//     FeeCollected. Neither of the two sources is complete on such deals — that is
//     the price of the transition, not a bug in the indexer.
//
// What does NOT degrade: deal statuses and money. FeeCollection is read by no
// interface, and no money path or lifecycle path depends on it. It is analytics — a
// breakdown of revenue by kind (six kinds) and nothing more. That is what
// distinguishes this item from the missing DisputeSplitNoVerdict handler, where
// without a handler a user sees a dispute as open when it no longer exists on chain.
//
// A delay does not lose data forever: subgraph.yaml holds startBlock: 44613049, a
// new version syncs from there, and so a v2.2.0 shipped later back-indexes
// FeeCollection retrospectively. The price of a delay is a window in which the
// revenue ledger is wrong, not a hole in the history.
//
// ── THE 3% DISPUTE FEE — WHAT WILL WORK AND WHAT WILL NOT ────────────────
// ArbiterRegistryFacet.creditDisputeFee/getTreasurySlice/withdrawTreasurySlice are
// mounted by THIS cut and are ready to take the fee — but there is nobody to call
// them yet. The fee is computed and transferred by Agreement.resolveDispute
// (DISPUTE_FEE_BPS = 300), and Agreement is NOT a facet: it is the implementation
// behind AgreementDeployer.implementation for the EIP-1167 clones (immutable, see
// above). The live clone deployer points at the Agreement deployed by
// UpgradeAgreementDeployerV5 on 27.07 — BEFORE the dispute fee reached the sources.
// Not one already existing clone (and not one retained pre-clone contract) will
// start taking 3% after THIS cut: the implementation is baked into the clone's
// bytecode forever and does not change retrospectively.
//
// For the fee to work on NEW deals a SEPARATE deployment is needed, and this script
// deliberately does not do it (the decision must not be made in silence):
//   1) script/UpgradeAgreementDisputeFee.s.sol is already written and is already
//      gated on creditDisputeFee being mounted (a real broadcast requires
//      facetAddress(creditDisputeFee.selector) != 0; a dry run always passes) — and
//      has never been broadcast. After THIS cut its precondition is already met and
//      it can be run straight away, without
//      script/UpgradeArbiterRegistryDisputeFee.s.sol (which became redundant — the
//      same three selectors will already be mounted by this script).
//   2) A RELEASE BLOCKER for step (1) and not for this cut: the
//      DisputeSplitNoVerdict handler is not deployed in the indexer — without it a
//      deal closed by a split with no claim stays in the "dispute" status in every
//      interface forever, although on chain it is already finalised. This cut does
//      not touch Agreement at all, so it is not itself a blocker.
//
// Usage (a dry run — always this one first):
//   forge script script/UpgradeFeeModel.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (a real run):
//   forge script script/UpgradeFeeModel.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../../src/DiamondProxy.sol";
import "../../src/FactoryFacet.sol";
import "../../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../../src/facets/ArbiterAccountabilityFacet.sol";
import "../../src/facets/JobBoardFacet.sol";
import "../../src/facets/ServiceBoardFacet.sol";
import "../../src/RegistryFacet.sol";
import "../../src/facets/DealMetadataFacet.sol";

contract UpgradeFeeModel is Script {

    // The fee model: the same defaults initFactory() sets on a fresh deployment (see
    // FactoryFacet.initFactory), so that after this upgrade the live diamond is
    // indistinguishable by configuration from a diamond deployed today from scratch.
    uint256 constant NEW_FEE_BPS     = 500;        // 5%
    uint256 constant NEW_FEE_FLOOR   = 1_000_000;  // 1 USDC (6 decimals)
    uint256 constant NEW_MAX_PENDING = 5;

    /// The offset of `feeFloor` inside FactoryStorage.Layout, in slots from
    /// FACTORY_STORAGE_POSITION. It is public so that
    /// test/UpgradeFeeModelSelectors.t.sol checks THIS number rather than repeating
    /// it on its own side: if the layout drifts, the upgrade test goes red and not
    /// only somebody else's fixture. The justification of the number is in
    /// readFeeFloorRaw() below.
    uint256 public constant FEE_FLOOR_SLOT_OFFSET = 9;

    function run() external {
        address diamond     = vm.envAddress("DIAMOND_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(deployerKey);

        // ── Pre-flight ────────────────────────────────────────────────────
        require(diamond != address(0), "UpgradeFeeModel: DIAMOND_ADDRESS is zero");
        require(diamond.code.length > 0, "UpgradeFeeModel: DIAMOND_ADDRESS has no code");

        address currentOwner = OwnershipFacet(diamond).owner();
        require(
            currentOwner == broadcaster,
            "UpgradeFeeModel: PRIVATE_KEY is not the diamond owner - diamondCut would revert after six paid facet deploys"
        );

        // feeFloor must be ZERO: initFeeModel (called in the _init of this cut)
        // reverts AlreadyInitialized on a non-zero floor and would bring the WHOLE cut
        // down, including six already paid-for Replace/Add — a cut is atomic, and
        // there is no partial application.
        //
        // getFeeFloor() IS NOT ITSELF MOUNTED YET on the live diamond — it is one of
        // the 14 Add selectors of this same script, and there is nothing to call it
        // with (checked by hand: the live chain reverts "Diamond: function not found"
        // on FactoryFacet(diamond).getFeeFloor() before this upgrade). The value is
        // read straight out of storage through readFeeFloorRaw below.
        uint256 currentFloor = readFeeFloorRaw(diamond);
        require(
            currentFloor == 0,
            "UpgradeFeeModel: feeFloor is already nonzero on chain - initFeeModel would revert AlreadyInitialized and take the whole cut down with it"
        );

        console.log("=== UpgradeFeeModel: pre-flight ===");
        console.log("Diamond: ", diamond);
        console.log("Owner:   ", currentOwner);
        console.log("Current feeFloor (must be 0):", currentFloor);
        console.log("");

        bytes4[] memory factoryReplace  = factoryFacetReplaceSelectors();
        bytes4[] memory factoryAdd      = factoryFacetAddSelectors();
        bytes4[] memory arbiterReplace  = arbiterRegistryFacetReplaceSelectors();
        bytes4[] memory arbiterAdd      = arbiterRegistryFacetAddSelectors();
        bytes4[] memory jobBoardReplace = jobBoardFacetReplaceSelectors();
        bytes4[] memory jobBoardAdd     = jobBoardFacetAddSelectors();
        bytes4[] memory serviceReplace  = serviceBoardFacetReplaceSelectors();
        bytes4[] memory serviceAdd      = serviceBoardFacetAddSelectors();
        bytes4[] memory registryReplace = registryFacetReplaceSelectors();
        bytes4[] memory metaReplace     = dealMetadataFacetReplaceSelectors();

        // Every Replace selector is mounted now, and all the selectors of one facet
        // point at ONE and the same live address (otherwise the Replace list for that
        // facet was derived wrongly).
        address oldFactory  = _checkReplaceGroup("FactoryFacet",         factoryReplace, diamond);
        address oldArbiter  = _checkReplaceGroup("ArbiterRegistryFacet", arbiterReplace, diamond);
        address oldJobBoard = _checkReplaceGroup("JobBoardFacet",        jobBoardReplace, diamond);
        address oldService  = _checkReplaceGroup("ServiceBoardFacet",    serviceReplace, diamond);
        address oldRegistry = _checkReplaceGroup("RegistryFacet",        registryReplace, diamond);
        address oldMeta     = _checkReplaceGroup("DealMetadataFacet",    metaReplace, diamond);

        // Not one of the 14 Add selectors is mounted anywhere on the diamond.
        _checkAddGroup("FactoryFacet",         factoryAdd, diamond);
        _checkAddGroup("ArbiterRegistryFacet", arbiterAdd, diamond);
        _checkAddGroup("JobBoardFacet",        jobBoardAdd, diamond);
        _checkAddGroup("ServiceBoardFacet",    serviceAdd, diamond);

        uint256 selectorsBefore = _totalRoutedSelectors(diamond);
        console.log("");
        console.log("Total routed selectors BEFORE cut:", selectorsBefore, "(expect 145)");
        console.log("");

        // ── The upgrade ───────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);

        FactoryFacet         newFactory  = new FactoryFacet();
        ArbiterRegistryFacet newArbiter  = new ArbiterRegistryFacet();
        JobBoardFacet        newJobBoard = new JobBoardFacet();
        ServiceBoardFacet    newService  = new ServiceBoardFacet();
        RegistryFacet        newRegistry = new RegistryFacet();
        DealMetadataFacet    newMeta     = new DealMetadataFacet();

        console.log("=== New facet implementations ===");
        console.log("FactoryFacet:         ", address(newFactory));
        console.log("ArbiterRegistryFacet: ", address(newArbiter));
        console.log("JobBoardFacet:        ", address(newJobBoard));
        console.log("ServiceBoardFacet:    ", address(newService));
        console.log("RegistryFacet:        ", address(newRegistry));
        console.log("DealMetadataFacet:    ", address(newMeta));
        console.log("");

        IDiamondCut.FacetCut[] memory cuts = buildFeeModelCuts(
            address(newFactory), address(newArbiter), address(newJobBoard),
            address(newService), address(newRegistry), address(newMeta)
        );

        IDiamondCut(diamond).diamondCut(
            cuts,
            address(newFactory),
            abi.encodeCall(FactoryFacet.initFeeModel, (NEW_FEE_BPS, NEW_FEE_FLOOR, NEW_MAX_PENDING))
        );

        vm.stopBroadcast();

        // ── Post-flight ───────────────────────────────────────────────────
        console.log("=== Post-flight ===");

        _assertRouted("FactoryFacet Replace",         factoryReplace,  address(newFactory),  diamond);
        _assertRouted("FactoryFacet Add",             factoryAdd,      address(newFactory),  diamond);
        _assertRouted("ArbiterRegistryFacet Replace", arbiterReplace,  address(newArbiter),  diamond);
        _assertRouted("ArbiterRegistryFacet Add",     arbiterAdd,      address(newArbiter),  diamond);
        _assertRouted("JobBoardFacet Replace",        jobBoardReplace, address(newJobBoard), diamond);
        _assertRouted("JobBoardFacet Add",            jobBoardAdd,     address(newJobBoard), diamond);
        _assertRouted("ServiceBoardFacet Replace",    serviceReplace,  address(newService),  diamond);
        _assertRouted("ServiceBoardFacet Add",        serviceAdd,      address(newService),  diamond);
        _assertRouted("RegistryFacet Replace",        registryReplace, address(newRegistry), diamond);
        _assertRouted("DealMetadataFacet Replace",    metaReplace,     address(newMeta),     diamond);

        require(IDiamondLoupe(diamond).facetFunctionSelectors(oldFactory).length == 0,  "post: old FactoryFacet still holds selectors");
        require(IDiamondLoupe(diamond).facetFunctionSelectors(oldArbiter).length == 0,  "post: old ArbiterRegistryFacet still holds selectors");
        require(IDiamondLoupe(diamond).facetFunctionSelectors(oldJobBoard).length == 0, "post: old JobBoardFacet still holds selectors");
        require(IDiamondLoupe(diamond).facetFunctionSelectors(oldService).length == 0,  "post: old ServiceBoardFacet still holds selectors");
        require(IDiamondLoupe(diamond).facetFunctionSelectors(oldRegistry).length == 0, "post: old RegistryFacet still holds selectors");
        require(IDiamondLoupe(diamond).facetFunctionSelectors(oldMeta).length == 0,     "post: old DealMetadataFacet still holds selectors");
        console.log("All six old facet addresses hold zero selectors (fully displaced).");
        console.log("");

        uint256 selectorsAfter = _totalRoutedSelectors(diamond);
        require(selectorsAfter == selectorsBefore + 14, "post: expected exactly +14 routed selectors after the cut");
        console.log("Total routed selectors AFTER cut: ", selectorsAfter, "(expect 159)");
        console.log("");

        uint256 feeBps   = FactoryFacet(diamond).getFeeBps();
        uint256 feeFloor = FactoryFacet(diamond).getFeeFloor();
        uint256 maxPend  = FactoryFacet(diamond).getMaxPendingRequests();
        uint256 quoted   = FactoryFacet(diamond).quoteFee(200_000_000); // 200 USDC

        console.log("getFeeBps():             ", feeBps,   "(expect 500)");
        console.log("getFeeFloor():           ", feeFloor, "(expect 1000000)");
        console.log("getMaxPendingRequests(): ", maxPend,  "(expect 5)");
        console.log("quoteFee(200e6):         ", quoted,   "(expect 10000000)");

        require(feeBps == NEW_FEE_BPS, "post: feeBps mismatch");
        require(feeFloor == NEW_FEE_FLOOR, "post: feeFloor mismatch");
        require(maxPend == NEW_MAX_PENDING, "post: maxPendingRequests mismatch");
        require(quoted == 10_000_000, "post: quoteFee(200e6) mismatch");

        // getAllFees() reverts FeeNotRegional() inside — from outside the diamond that
        // is visible as success=false on a low-level .call.
        (bool okAllFees, ) = diamond.call(abi.encodeWithSelector(FactoryFacet.getAllFees.selector));
        require(!okAllFees, "post: getAllFees() should revert (region fees are retired) but it succeeded");
        console.log("getAllFees() reverts as expected:", !okAllFees);
        console.log("");

        console.log("=== Fee model live on chain ===");
        console.log("500 bps (5%) with a 1 USDC floor, max 5 pending requests per client.");
        console.log("");
        console.log("=== Still needed for the dispute fee to actually collect (separate decision) ===");
        console.log("script/UpgradeAgreementDisputeFee.s.sol - deploys a new Agreement impl +");
        console.log("AgreementDeployer + setAgreementDeployer. Its own gate now passes: this cut");
        console.log("mounted creditDisputeFee. Blocked on the missing indexer handler.");
        console.log("");

        console.log("=== Rollback ===");
        console.log("One diamondCut: Replace each of the six groups above back onto <old*>, PLUS");
        console.log("Remove (action 2, facetAddress MUST be address(0) - see DiamondCutLib.removeFunctions)");
        console.log("of the 14 Add selectors, in the SAME cut.");
        console.log("");
        console.log("Never Replace the 14 Add selectors onto an old facet. That cut does NOT");
        console.log("revert - replaceFunctions only checks the target facet is a DIFFERENT address");
        console.log("that has SOME code, never that it implements the selector. It succeeds, loupe");
        console.log("reports the selector mounted, and every call to it reverts with empty");
        console.log("returndata. Silent and invisible to facet-level monitoring. Remove is the");
        console.log("only correct action for them. Same warning: docs/RUNBOOK-dispute-settlement.md.");
        console.log("  <old FactoryFacet>         =", oldFactory);
        console.log("  <old ArbiterRegistryFacet> =", oldArbiter);
        console.log("  <old JobBoardFacet>        =", oldJobBoard);
        console.log("  <old ServiceBoardFacet>    =", oldService);
        console.log("  <old RegistryFacet>        =", oldRegistry);
        console.log("  <old DealMetadataFacet>    =", oldMeta);
    }

    // ════════════════════════════════════════════════════════════════════
    // Pre/post-flight helpers
    // ════════════════════════════════════════════════════════════════════

    /// Checks that every selector in the group is mounted (otherwise Replace reverts
    /// "selector not exist" in DiamondCutLib.replaceFunctions) and that they all
    /// point at ONE and the same current address — if they do not, the Replace list
    /// for that facet was derived wrongly (part of the functions has already moved to
    /// another facet, say). Returns that address.
    function _checkReplaceGroup(string memory label, bytes4[] memory sels, address diamond)
        internal view returns (address facetAddr)
    {
        require(sels.length > 0, string.concat(label, ": replace group is empty"));
        facetAddr = IDiamondLoupe(diamond).facetAddress(sels[0]);
        require(facetAddr != address(0), string.concat(label, ": selector[0] is not mounted at all"));
        for (uint256 i = 0; i < sels.length; i++) {
            address a = IDiamondLoupe(diamond).facetAddress(sels[i]);
            require(a != address(0), string.concat(label, ": a replace selector is not mounted"));
            require(a == facetAddr, string.concat(label, ": replace selectors are split across more than one live facet address"));
        }
        console.log(string.concat(label, " currently mounted at:"), facetAddr);
        console.log(string.concat(label, " selectors to Replace:"), sels.length);
    }

    /// Checks that not one selector in the group is mounted yet — otherwise Add
    /// reverts "selector exists" in DiamondCutLib.addFunctions.
    function _checkAddGroup(string memory label, bytes4[] memory sels, address diamond) internal view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == address(0),
                string.concat(label, ": an Add selector is already mounted somewhere - Add would revert")
            );
        }
        console.log(string.concat(label, " selectors to Add (currently unmounted):"), sels.length);
    }

    function _assertRouted(string memory label, bytes4[] memory sels, address expected, address diamond) internal view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                string.concat(label, ": a selector did not land on the new facet")
            );
        }
        console.log(string.concat(label, " -> "), expected);
    }

    function _totalRoutedSelectors(address diamond) internal view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(diamond).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    /// Reads `FactoryStorage.Layout.feeFloor` straight out of the diamond's storage,
    /// because getFeeFloor() (like getFeeBps()/getMaxPendingRequests()) is itself one
    /// of the 14 Add selectors of this script — before the broadcast there is
    /// physically nothing to call it with, `Diamond: function not found`.
    ///
    /// The offset inside FactoryStorage.Layout (10 fields before feeFloor, packing
    /// taken into account):
    ///   +0 usdc, +1 feeRecipient, +2 regionFee (a mapping — it reserves a whole
    ///   slot), +3 trustedForwarder, +4 diamond+paused (packed together, since
    ///   20+1 <= 32 bytes), +5 protocolArbiter, +6 arbitrationThreshold,
    ///   +7 agreementDeployer, +8 feeBps, +9 feeFloor, +10 maxPendingRequests.
    /// The layout is append-only (a gate enforces that), so the offset +9 is stable
    /// forever and not merely today — new fields are appended STRICTLY at the end and
    /// existing ones never shift.
    ///
    /// public rather than internal for the same reason as buildFeeModelCuts above:
    /// test/UpgradeFeeModelSelectors.t.sol calls THIS VERY function against a local
    /// diamond where feeFloor is set through getFeeFloor()/setFeeFloor(), that is,
    /// through the real layout. If the offset drifts, the upgrade test goes red and
    /// not only BoardsFixture._unconfigureFeeModel.
    function readFeeFloorRaw(address diamond) public view returns (uint256) {
        bytes32 base = FactoryStorage.FACTORY_STORAGE_POSITION;
        bytes32 slot = bytes32(uint256(base) + FEE_FLOOR_SLOT_OFFSET);
        return uint256(vm.load(diamond, slot));
    }

    // ════════════════════════════════════════════════════════════════════
    // The FacetCut[] builder — extracted into a public pure function so that
    // test/UpgradeFeeModelSelectors.t.sol can compare its output against the live
    // ABIs without running the script again. run() above builds its cuts through this
    // very function and duplicates nothing by hand.
    // ════════════════════════════════════════════════════════════════════

    function buildFeeModelCuts(
        address factoryAddr,
        address arbiterAddr,
        address jobBoardAddr,
        address serviceBoardAddr,
        address registryAddr,
        address dealMetaAddr
    ) public pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](10);
        cuts[0] = _cut(factoryAddr,      IDiamondCut.FacetCutAction.Replace, factoryFacetReplaceSelectors());
        cuts[1] = _cut(factoryAddr,      IDiamondCut.FacetCutAction.Add,     factoryFacetAddSelectors());
        cuts[2] = _cut(arbiterAddr,      IDiamondCut.FacetCutAction.Replace, arbiterRegistryFacetReplaceSelectors());
        cuts[3] = _cut(arbiterAddr,      IDiamondCut.FacetCutAction.Add,     arbiterRegistryFacetAddSelectors());
        cuts[4] = _cut(jobBoardAddr,     IDiamondCut.FacetCutAction.Replace, jobBoardFacetReplaceSelectors());
        cuts[5] = _cut(jobBoardAddr,     IDiamondCut.FacetCutAction.Add,     jobBoardFacetAddSelectors());
        cuts[6] = _cut(serviceBoardAddr, IDiamondCut.FacetCutAction.Replace, serviceBoardFacetReplaceSelectors());
        cuts[7] = _cut(serviceBoardAddr, IDiamondCut.FacetCutAction.Add,     serviceBoardFacetAddSelectors());
        cuts[8] = _cut(registryAddr,     IDiamondCut.FacetCutAction.Replace, registryFacetReplaceSelectors());
        cuts[9] = _cut(dealMetaAddr,     IDiamondCut.FacetCutAction.Replace, dealMetadataFacetReplaceSelectors());
    }

    // ── Per-facet selector arrays (ground truth: `forge inspect <Facet> methodIdentifiers`) ──
    // Split Replace (already on chain today) vs. Add (the 14 new selectors),
    // per the table verified against facets() on the live diamond.

    // FactoryFacet — 13 Replace (unchanged signatures) + 8 Add (fee model)
    function factoryFacetReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](13);
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
    }

    function factoryFacetAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](8);
        sels[0] = FactoryFacet.setFeeBps.selector;
        sels[1] = FactoryFacet.setFeeFloor.selector;
        sels[2] = FactoryFacet.setMaxPendingRequests.selector;
        sels[3] = FactoryFacet.quoteFee.selector;
        sels[4] = FactoryFacet.getFeeBps.selector;
        sels[5] = FactoryFacet.getFeeFloor.selector;
        sels[6] = FactoryFacet.getMaxPendingRequests.selector;
        sels[7] = FactoryFacet.initFeeModel.selector;
    }

    // ArbiterRegistryFacet — 44 Replace (unchanged) + 3 Add (dispute fee ledger)
    function arbiterRegistryFacetReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](44);
        sels[0]  = ArbiterRegistryFacet.activateDAO.selector;
        sels[1]  = ArbiterRegistryFacet.applyAsArbiter.selector;
        sels[2]  = ArbiterRegistryFacet.resignAsArbiter.selector;
        sels[3]  = ArbiterRegistryFacet.setChiefArbiter.selector;
        sels[4]  = ArbiterRegistryFacet.addArbiter.selector;
        sels[5]  = bytes4(0x3487e08c) /* removeArbiter(address), removed 15 August 2026 */;
        sels[6]  = ArbiterRegistryFacet.commitDisputeClaim.selector;
        sels[7]  = bytes4(keccak256("claimDispute(address,bytes32)")) /* frozen: old 2-arg selector, historical cut */;
        sels[8]  = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        sels[9]  = ArbiterRegistryFacet.clearDisputeClaim.selector;
        sels[10] = ArbiterRegistryFacet.submitVerdict.selector;
        sels[11] = ArbiterRegistryFacet.finalizeVerdict.selector;
        sels[12] = ArbiterRegistryFacet.overturnVerdict.selector;
        sels[13] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        sels[14] = ArbiterRegistryFacet.freezeVerdict.selector;
        sels[15] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        sels[16] = ArbiterRegistryFacet.clearStuckVerdict.selector;
        sels[17] = ArbiterRegistryFacet.raiseAppeal.selector;
        sels[18] = ArbiterRegistryFacet.voteOnAppeal.selector;
        sels[19] = ArbiterRegistryFacet.resolveAppeal.selector;
        sels[20] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        sels[21] = ArbiterRegistryFacet.fundVault.selector;
        sels[22] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        sels[23] = ArbiterRegistryFacet.setDAOAddress.selector;
        sels[24] = ArbiterRegistryFacet.isDaoActive.selector;
        sels[25] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        sels[26] = ArbiterRegistryFacet.getDaoThreshold.selector;
        sels[27] = ArbiterRegistryFacet.getChiefArbiter.selector;
        sels[28] = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        sels[29] = ArbiterRegistryFacet.getArbiters.selector;
        sels[30] = ArbiterRegistryFacet.getDisputeClaimer.selector;
        sels[31] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        sels[32] = ArbiterRegistryFacet.getClaimCommitment.selector;
        sels[33] = ArbiterRegistryFacet.getPendingVerdict.selector;
        sels[34] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        sels[35] = ArbiterRegistryFacet.getVaultBalance.selector;
        sels[36] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        sels[37] = ArbiterRegistryFacet.getDAOAddress.selector;
        sels[38] = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;
        sels[39] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        sels[40] = ArbiterRegistryFacet.getAppealVotes.selector;
        sels[41] = ArbiterRegistryFacet.hasVotedOnAppeal.selector;
        sels[42] = ArbiterAccountabilityFacet.getArbiterBond.selector;
        sels[43] = ArbiterAccountabilityFacet.getOpenClaimCount.selector;
    }

    function arbiterRegistryFacetAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](3);
        sels[0] = ArbiterRegistryFacet.creditDisputeFee.selector;
        sels[1] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        sels[2] = ArbiterRegistryFacet.getTreasurySlice.selector;
    }

    // JobBoardFacet — 12 Replace (unchanged) + 1 Add (fee-held getter)
    function jobBoardFacetReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](12);
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
    }

    function jobBoardFacetAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = JobBoardFacet.getJobFeeHeld.selector;
    }

    // ServiceBoardFacet — 23 Replace (unchanged) + 2 Add (fee-held + pending count)
    function serviceBoardFacetReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](23);
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
    }

    function serviceBoardFacetAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](2);
        sels[0] = ServiceBoardFacet.getRequestFeeHeld.selector;
        sels[1] = ServiceBoardFacet.getPendingRequestCount.selector;
    }

    // RegistryFacet — 13 Replace, 0 Add (error rename only, ABI unchanged)
    function registryFacetReplaceSelectors() public pure returns (bytes4[] memory sels) {
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

    function registryFacetAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](0);
    }

    // DealMetadataFacet — 1 Replace, 0 Add (domain fix in SVG only)
    function dealMetadataFacetReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = DealMetadataFacet.getDealTokenURI.selector;
    }

    function dealMetadataFacetAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](0);
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory sels)
        internal pure returns (IDiamondCut.FacetCut memory)
    {
        return IDiamondCut.FacetCut({ facetAddress: facet, action: action, functionSelectors: sels });
    }
}
