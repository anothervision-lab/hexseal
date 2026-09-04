// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeEmergencyBrake.s.sol
//
// THE MARKETPLACE GETS A BRAKE THAT LETS GO BY ITSELF (decision 17), AND THE
// FACTORY'S TWO OTHER PENDING REPAIRS RIDE WITH IT. ONE diamondCut, FOUR
// elements:
//
//   Replace 23 -> new FactoryFacet        (the writer, the gate on both
//                                          deal-creating doors, the zero check
//                                          on setTrustedForwarder, and the fee
//                                          ceiling behind a name)
//   Add      5 -> the SAME new FactoryFacet
//                                          pauseNewDeals()
//                                          resumeNewDeals()
//                                          newDealsPausedUntil()
//                                          NEW_DEALS_PAUSE_DURATION()
//                                          MAX_FEE_BPS()
//   Replace 13 -> new JobBoardFacet       (whenNotPaused reads the clock)
//   Replace 25 -> new ServiceBoardFacet   (whenNotPaused reads the clock)
//
//   13 facets -> 13 facets, routed selectors 222 -> 227
//
// ⚠️ TWO OF THE THREE CHANGES ARE INVISIBLE IN THIS LIST, AND THAT IS THE POINT
// OF SAYING THEM HERE. `setTrustedForwarder` gains
// `if (newForwarder == address(0)) revert FactoryZeroAddress()` -- the same
// decision `initFactory` already took about the same field, which the setter
// had never carried. Its selector does not move, so it rides in the Replace
// group above and nothing in the cut's SHAPE records that it changed. The
// second is `MAX_FEE_BPS`, which replaces the bare `2_000` that stood in
// `initFeeModel` and `setFeeBps`; that one IS visible, as the fifth Add.
//
// WHAT IS WRONG TODAY. Both boards carry a `whenNotPaused` modifier on their
// money doors, and it reads `FactoryStorage.Layout.paused` -- a bool that has
// had NO WRITER since `setPaused` was removed on 24 June 2026. Ten weeks of a
// guard that cannot be armed. `deployAndFund`, the factory's own door, carries
// no gate at all. So the protocol's emergency stop, as shipped, is an ornament
// on nine doors and absent from the tenth.
//
// WHAT SHIPS. A timestamp, `newDealsPausedUntil`, APPENDED to the tail of
// `FactoryStorage.Layout`, and one reader, `FactoryStorage.newDealsPaused`,
// called from all three facets. Down means "no new money enters"; it lets go on
// its own after NEW_DEALS_PAUSE_DURATION (72 hours), and the owner can let it
// go early.
//
// ⚠️ WHY THE FIVE NEW SELECTORS ARE A GROUP OF THEIR OWN AND NOT FOLDED INTO
// THE FACTORY'S Replace. That is decision 55 (docs/DECISIONS.md), taken on
// 31 August after the same shortcut was proposed and refused: "Приклеить к ней
// `Add` значит эту защиту снять ради экономии одной транзакции". `Replace`
// reverts on a selector that is NOT mounted; `Add` reverts on one that IS.
// A cut written as a single quiet Replace has no pair that can drop it, which
// sounds like a virtue and is the opposite: the five new functions would have
// to be smuggled in as if they were already routed, and `Replace` would revert
// on the first of them. They are declared out loud, in their own element, and
// the pre-flight below asks the CHAIN -- not this file -- which group each
// selector belongs in.
//
// ⚠️ ORDER, AND WHY THERE IS NO WINDOW. The writer (FactoryFacet) and the
// readers (both boards) travel in ONE diamondCut. `LibDiamond.diamondCut` is a
// single loop over the elements inside a single transaction
// (src/DiamondProxy.sol) -- every element lands or none does, and nothing can
// interleave between them. So the order of the four elements is cosmetic, and
// it is checked to be cosmetic: the Add group's five selectors are unmounted
// both before and after the Factory Replace (a Replace never mounts anything
// new), so no element depends on another having run first.
//
// If this ever HAD to be split into two signed transactions, the factory goes
// FIRST and the boards second. Between the two:
//
//   * Factory first: the brake is pressable, and the two doors where money
//     actually enters (`deployAgreement`, `deployAndFund`) already refuse.
//     The boards still consult the dead bool, so `mintJob`/`mintService`/
//     `editJob` stay open -- but every board path that MOVES money ends in
//     `deployAgreement`, so it reverts with `FactoryPaused()`, which is the
//     same selector (0x68c2f226) the boards already use and which the relay
//     tables and all fourteen locales already decode. Degraded, and degraded
//     in the safe direction.
//
//   * Boards first: the boards read a clock that has no writer -- the field is
//     an untouched slot, so it reads zero, so nothing is ever braked -- and
//     `pauseNewDeals()` is not mounted yet, so the brake cannot be pressed at
//     all. Nothing breaks, but for the length of the window the protocol has a
//     safety device that looks armed and is not, which is the single worst
//     state a safety device can be in.
//
// THE STORAGE IS APPENDED TO, NEVER REORDERED. One new `uint256` at the end of
// `FactoryStorage.Layout`. The dead `paused` bool stays exactly where it is,
// packed in the tail of slot 4 -- not reused, not removed. Slots on a live
// diamond are never renumbered (docs/CONTRACT_GUIDE.md), and the July 2026
// `termsHash -> terms` accident is what that rule is made of. The post-flight
// below reads eight witnesses across the cut and refuses if any of them moved,
// which is how an append that silently landed on an occupied slot would be
// caught: `newDealsPausedUntil()` answering anything but zero on a diamond that
// has never been braked means the field is aliasing something else.
//
// WHAT THIS CUT DOES NOT REACH. Every deal that already exists. A deal is an
// EIP-1167 clone nailed to its implementation for life; replacing a facet
// cannot touch one, and pressing the brake is not a way to freeze a live deal.
// Eight deals are on record today and all eight keep running while the brake is
// down -- which is the design, not a gap: decision 17 says so outright.
//
// The diamond address comes from the environment and is never hardcoded.
//
// Usage (dry run -- always this one first, it sends no transaction):
//   forge script script/UpgradeEmergencyBrake.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeEmergencyBrake.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {FactoryFacet, FactoryStorage} from "../src/FactoryFacet.sol";
import {JobBoardFacet} from "../src/facets/JobBoardFacet.sol";
import {ServiceBoardFacet} from "../src/facets/ServiceBoardFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

contract UpgradeEmergencyBrake is Script {

    /// Build artifacts this script holds its own selector lists against.
    /// Read through `vm.readFile`; `./out` is already in `fs_permissions`.
    string internal constant FACTORY_ARTIFACT = "out/FactoryFacet.sol/FactoryFacet.json";
    string internal constant JOBBOARD_ARTIFACT = "out/JobBoardFacet.sol/JobBoardFacet.json";
    string internal constant SERVICEBOARD_ARTIFACT = "out/ServiceBoardFacet.sol/ServiceBoardFacet.json";

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeEmergencyBrake.s.sol";
    }

    /// The duration one press holds. Held here as a literal rather than read
    /// off the facet on purpose: the post-flight compares the two, and a
    /// comparison where both sides come from the same place proves nothing.
    uint256 public constant EXPECTED_PAUSE_DURATION = 72 hours;

    // ════════════════════════════════════════════════════════════════════
    // The four groups, written out by hand
    // ════════════════════════════════════════════════════════════════════
    //
    // Hand-written, and NOT derived from the artifacts, even though a helper
    // below can read them. The artifact answers "what does the facet
    // implement"; these lists answer "which group does each one go in", and
    // that second question is the one the chain punishes. Deriving the lists
    // from the artifact would make the two answers the same answer.

    /// Mounted today on 0x3E8DbC22..., and moving to the new facet address.
    /// Twenty-three, read off the chain at block 46306403 and cross-checked
    /// against solc's own `methodIdentifiers` by `assertListsCoverTheCompiledFacets`.
    function factoryReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](23);
        sels[0]  = FactoryFacet.initFactory.selector;
        sels[1]  = FactoryFacet.initFeeModel.selector;
        sels[2]  = FactoryFacet.deployAgreement.selector;
        sels[3]  = FactoryFacet.deployAndFund.selector;
        sels[4]  = FactoryFacet.setRegionFee.selector;
        sels[5]  = FactoryFacet.setFeeBps.selector;
        sels[6]  = FactoryFacet.setFeeFloor.selector;
        sels[7]  = FactoryFacet.setFeeRecipient.selector;
        sels[8]  = FactoryFacet.setMaxPendingRequests.selector;
        sels[9]  = FactoryFacet.setTrustedForwarder.selector;
        sels[10] = FactoryFacet.setAgreementDeployer.selector;
        sels[11] = FactoryFacet.getRegionFee.selector;
        sels[12] = FactoryFacet.getAllFees.selector;
        sels[13] = FactoryFacet.getFeeBps.selector;
        sels[14] = FactoryFacet.getFeeFloor.selector;
        sels[15] = FactoryFacet.getFeeRecipient.selector;
        sels[16] = FactoryFacet.quoteFee.selector;
        sels[17] = FactoryFacet.getMaxPendingRequests.selector;
        sels[18] = FactoryFacet.getTrustedForwarder.selector;
        sels[19] = FactoryFacet.getUsdc.selector;
        sels[20] = FactoryFacet.getAgreementDeployer.selector;
        sels[21] = FactoryFacet.getUndeliveredFees.selector;
        sels[22] = FactoryFacet.withdrawUndeliveredFees.selector;
    }

    /// Mounted NOWHERE today -- confirmed against the live diamond at block
    /// 46306403, all five answering `facetAddress()` with the zero address.
    /// The whole delivery of this cut.
    ///
    /// Four of the five are the brake. The fifth, `MAX_FEE_BPS()`, is item 138:
    /// the 20% ceiling on the fee rate, which until now was a bare `2_000`
    /// written twice -- once in `initFeeModel`, once in `setFeeBps` -- with no
    /// name on either copy and no way for anything off-chain to read it. It is
    /// in this cut and not in one of its own because it lands on the same facet
    /// that is being replaced anyway: a second cut for one getter would mean a
    /// second FactoryFacet deployment and a second window.
    ///
    /// `NEW_DEALS_PAUSE_DURATION` and `MAX_FEE_BPS` are public constants, and
    /// Solidity exposes `.selector` only for functions, so their getters are
    /// spelled out. The signature text is the source of the four bytes here;
    /// the artifact is the source of the four bytes on the other side of the
    /// comparison.
    function factoryAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](5);
        sels[0] = FactoryFacet.pauseNewDeals.selector;
        sels[1] = FactoryFacet.resumeNewDeals.selector;
        sels[2] = FactoryFacet.newDealsPausedUntil.selector;
        sels[3] = bytes4(keccak256("NEW_DEALS_PAUSE_DURATION()"));
        sels[4] = bytes4(keccak256("MAX_FEE_BPS()"));
    }

    /// Mounted today on 0x1DD5ff70..., moving to the new facet. Nothing is
    /// added or removed here -- the board changes one line inside
    /// `whenNotPaused` and its ABI does not move.
    function jobBoardReplaceSelectors() public pure returns (bytes4[] memory sels) {
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

    /// Mounted today on 0xef581FEF..., moving to the new facet. Same shape of
    /// change as the job board: one line inside `whenNotPaused`.
    function serviceBoardReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](25);
        sels[0]  = ServiceBoardFacet.mintService.selector;
        sels[1]  = ServiceBoardFacet.mintServiceWithPermit.selector;
        sels[2]  = ServiceBoardFacet.editService.selector;
        sels[3]  = ServiceBoardFacet.pauseService.selector;
        sels[4]  = ServiceBoardFacet.unpauseService.selector;
        sels[5]  = ServiceBoardFacet.removeService.selector;
        sels[6]  = ServiceBoardFacet.requestService.selector;
        sels[7]  = ServiceBoardFacet.requestServiceWithPermit.selector;
        sels[8]  = ServiceBoardFacet.acceptRequest.selector;
        sels[9]  = ServiceBoardFacet.rejectRequest.selector;
        sels[10] = ServiceBoardFacet.cancelRequest.selector;
        sels[11] = ServiceBoardFacet.getService.selector;
        sels[12] = ServiceBoardFacet.getExecutorServices.selector;
        sels[13] = ServiceBoardFacet.getServiceClients.selector;
        sels[14] = ServiceBoardFacet.getRequest.selector;
        sels[15] = ServiceBoardFacet.getServiceRequests.selector;
        sels[16] = ServiceBoardFacet.getClientRequests.selector;
        sels[17] = ServiceBoardFacet.getRequestFunds.selector;
        sels[18] = ServiceBoardFacet.getRequestFeeHeld.selector;
        sels[19] = ServiceBoardFacet.getPendingRequests.selector;
        sels[20] = ServiceBoardFacet.getPendingRequestCount.selector;
        sels[21] = ServiceBoardFacet.getPendingRequestIdsByClientAndExecutor.selector;
        sels[22] = ServiceBoardFacet.getActiveServices.selector;
        sels[23] = ServiceBoardFacet.totalServices.selector;
        sels[24] = ServiceBoardFacet.totalRequests.selector;
    }

    /// The writer's Replace and the writer's Add come first, then the two
    /// readers. Reading order for a person, not an ordering constraint -- see
    /// the header: this is one transaction, and the stand proves the four
    /// elements do not depend on each other by rehearsing the cut with the
    /// groups in a different order.
    function buildCuts(address factory, address jobBoard, address serviceBoard)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress:      factory,
            action:            IDiamondCut.FacetCutAction.Replace,
            functionSelectors: factoryReplaceSelectors()
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress:      factory,
            action:            IDiamondCut.FacetCutAction.Add,
            functionSelectors: factoryAddSelectors()
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress:      jobBoard,
            action:            IDiamondCut.FacetCutAction.Replace,
            functionSelectors: jobBoardReplaceSelectors()
        });
        cuts[3] = IDiamondCut.FacetCut({
            facetAddress:      serviceBoard,
            action:            IDiamondCut.FacetCutAction.Replace,
            functionSelectors: serviceBoardReplaceSelectors()
        });
    }

    // ════════════════════════════════════════════════════════════════════
    // run
    // ════════════════════════════════════════════════════════════════════

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        // The signer comes from the command line (--account / --private-key), never
        // from the environment. Foundry fills msg.sender from --sender and derives it
        // from --private-key; with no wallet named at all it stays forge-std's
        // DEFAULT_SENDER, which is how a dry run identifies itself below.
        address broadcaster = msg.sender;

        // ── Pre-flight: everything checkable before a wei is spent ─────────
        require(diamond != address(0), "upgrade: DIAMOND_ADDRESS is zero");
        require(diamond.code.length > 0, "upgrade: DIAMOND_ADDRESS has no code");

        // Code is not enough. TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT
        // live in the same .env and all three have code, so a typo would sail
        // through the check above. Probe a selector only this diamond answers.
        address currentOwner = _readAddress(diamond, "owner()");
        if (broadcaster == DEFAULT_SENDER) {
            // A dry run with nobody named as the signer. Every chain read above still
            // ran; the only thing not checkable is WHO signs, because nothing said.
            // Foundry itself refuses to broadcast from DEFAULT_SENDER ("You seem to be
            // using Foundry's default sender"), so no live run can reach the cut
            // through this branch -- the check is skipped only when there is nothing
            // left to protect.
            console.log("NOTE: no signer named (--account/--sender absent).");
            console.log("      Ownership is NOT checked in this run. The live run needs:");
            console.log("      --account deployer --sender", currentOwner);
        } else {
            require(
                currentOwner == broadcaster,
                "upgrade: the signer is not the diamond owner - diamondCut would revert after a paid deploy"
            );
        }

        bytes4[] memory facSels = factoryReplaceSelectors();
        bytes4[] memory addSels = factoryAddSelectors();
        bytes4[] memory jobSels = jobBoardReplaceSelectors();
        bytes4[] memory svcSels = serviceBoardReplaceSelectors();

        // The hand-written lists against solc's own output, both ways.
        assertListsCoverTheCompiledFacets(facSels, addSels, jobSels, svcSels);
        _assertDisjoint(facSels, addSels);

        // Replace groups: every one of them mounted TODAY, and each group all
        // on one facet, or `Replace` reverts and takes the cut with it.
        address previousFactory      = assertAllMountedOnOneFacet(facSels, diamond);
        address previousJobBoard     = assertAllMountedOnOneFacet(jobSels, diamond);
        address previousServiceBoard = assertAllMountedOnOneFacet(svcSels, diamond);
        require(
            previousFactory != previousJobBoard
                && previousFactory != previousServiceBoard
                && previousJobBoard != previousServiceBoard,
            "pre-flight: two of the three groups sit on the same facet - this cut assumes three"
        );

        // And each facet must expose nothing else, or the cut leaves a selector
        // pointing at an address that no longer implements it.
        assertNothingIsLeftBehind(facSels, previousFactory, diamond);
        assertNothingIsLeftBehind(jobSels, previousJobBoard, diamond);
        assertNothingIsLeftBehind(svcSels, previousServiceBoard, diamond);

        // Add group: mounted NOWHERE in the whole diamond, not merely absent
        // from FactoryFacet. `Add` reverts on a selector routed anywhere.
        assertAddGroupIsUnmountedAnywhere(addSels, diamond);

        // The brake must not already exist. Asked of the DOOR, not of the loupe
        // -- a diamond where this cut has already landed answers the call, and
        // that is a different failure from "the selector is routed somewhere".
        assertTheBrakeIsNotThereYet(diamond);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        uint256 facetsBefore    = IDiamondLoupe(diamond).facetAddresses().length;
        StorageSnapshot memory beforeCut = snapshotFactoryAndBoards(diamond);

        console.log("=== UpgradeEmergencyBrake: pre-flight ===");
        console.log("Diamond:                           ", diamond);
        console.log("Owner (the only one who may press): ", currentOwner);
        console.log("Current FactoryFacet:              ", previousFactory);
        console.log("Current JobBoardFacet:             ", previousJobBoard);
        console.log("Current ServiceBoardFacet:         ", previousServiceBoard);
        console.log("Facets BEFORE cut:                 ", facetsBefore);
        console.log("Routed selectors BEFORE cut:       ", selectorsBefore);
        console.log("");
        console.log("--- what this cut will do, element by element ---");
        console.log("[0] Replace (FactoryFacet):        ", facSels.length);
        console.log("[1] Add     (FactoryFacet, new):   ", addSels.length);
        console.log("[2] Replace (JobBoardFacet):       ", jobSels.length);
        console.log("[3] Replace (ServiceBoardFacet):   ", svcSels.length);
        console.log("    Replace total:                 ", facSels.length + jobSels.length + svcSels.length);
        console.log("    Add total:                     ", addSels.length);
        console.log("Routed selectors AFTER cut will be:", selectorsBefore + addSels.length);
        console.log("");
        console.log("--- the five selectors being ADDED, out loud (decision 55) ---");
        console.log("  pauseNewDeals()             ", vm.toString(bytes.concat(addSels[0])));
        console.log("  resumeNewDeals()            ", vm.toString(bytes.concat(addSels[1])));
        console.log("  newDealsPausedUntil()       ", vm.toString(bytes.concat(addSels[2])));
        console.log("  NEW_DEALS_PAUSE_DURATION()  ", vm.toString(bytes.concat(addSels[3])));
        console.log("  MAX_FEE_BPS()               ", vm.toString(bytes.concat(addSels[4])));
        console.log("");
        console.log("--- witnesses read before the cut, checked again after ---");
        console.log("Jobs on the board:                 ", beforeCut.totalJobs);
        console.log("Services on the board:             ", beforeCut.totalServices);
        console.log("Requests on the board:             ", beforeCut.totalRequests);
        console.log("Fee rate (bps):                    ", beforeCut.feeBps);
        console.log("Fee floor:                         ", beforeCut.feeFloor);
        console.log("Max pending requests:              ", beforeCut.maxPendingRequests);
        console.log("Fee recipient:                     ", beforeCut.feeRecipient);
        console.log("Agreement deployer:                ", beforeCut.agreementDeployer);
        console.log("");

        // ⚠️ SAID OUT LOUD BECAUSE NOTHING HERE CAN REFUSE IT. This cut mounts
        // the brake in the "up" position and nothing more: the appended field
        // is an untouched slot, so it reads zero, so nothing is braked the
        // moment this lands. Somebody has to press it, and only the owner can.
        console.log("NOTE: this cut brakes NOTHING by itself. The field it appends reads zero,");
        console.log("      which means 'not braked'. It has to be pressed, by the owner, and");
        console.log("      every press is one signed transaction with a name against it.");
        console.log("NOTE: deals that already exist are NOT touched and cannot be. Eight are on");
        console.log("      record; each is an EIP-1167 clone running on its own clock, and the");
        console.log("      brake stands on the birth of a deal, not on a live one.");
        console.log("");

        // ── The cut ────────────────────────────────────────────────────────
        vm.startBroadcast();
        FactoryFacet factoryFacet          = new FactoryFacet();
        JobBoardFacet jobBoardFacet        = new JobBoardFacet();
        ServiceBoardFacet serviceBoardFacet = new ServiceBoardFacet();
        IDiamondCut(diamond).diamondCut(
            buildCuts(address(factoryFacet), address(jobBoardFacet), address(serviceBoardFacet)),
            address(0),
            ""
        );
        vm.stopBroadcast();

        console.log("New FactoryFacet:      ", address(factoryFacet));
        console.log("New JobBoardFacet:     ", address(jobBoardFacet));
        console.log("New ServiceBoardFacet: ", address(serviceBoardFacet));
        console.log("");

        // ── Post-flight: read the result back, do not assume it ────────────
        console.log("=== Post-flight ===");
        assertRouted(facSels, address(factoryFacet), diamond);
        assertRouted(addSels, address(factoryFacet), diamond);
        assertRouted(jobSels, address(jobBoardFacet), diamond);
        assertRouted(svcSels, address(serviceBoardFacet), diamond);
        console.log("All sixty-one replaced selectors and the five new ones land where they should.");

        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(factoryFacet)).length
                == facSels.length + addSels.length,
            "post-flight: the new FactoryFacet does not hold the replaced selectors plus the five new ones"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousFactory).length == 0
                && IDiamondLoupe(diamond).facetFunctionSelectors(previousJobBoard).length == 0
                && IDiamondLoupe(diamond).facetFunctionSelectors(previousServiceBoard).length == 0,
            "post-flight: an old facet still holds selectors - a Replace did not move all of them"
        );
        require(
            IDiamondLoupe(diamond).facetAddresses().length == facetsBefore,
            "post-flight: the facet count moved - the old facets should have been emptied, not unmounted"
        );
        require(
            totalRoutedSelectors(diamond) == selectorsBefore + addSels.length,
            "post-flight: the routed selector count moved by something other than the Add group"
        );

        assertTheBrakeIsUpAndRefusesAStranger(diamond);
        console.log("The brake answers, reads UP, states its own 72 hours, and refuses a stranger.");

        assertStorageUnmoved(beforeCut, snapshotFactoryAndBoards(diamond));
        console.log("Storage continuity OK: eight witnesses read the same on both sides of the cut.");

        console.log("");
        console.log("Facets AFTER cut:            ", IDiamondLoupe(diamond).facetAddresses().length);
        console.log("Routed selectors AFTER cut:  ", totalRoutedSelectors(diamond));
        console.log("");
        console.log("To press the brake (owner only, holds 72 hours, lets go by itself):");
        console.log("  cast send $DIAMOND_ADDRESS \"pauseNewDeals()\" --account deployer");
        console.log("To let it go early:");
        console.log("  cast send $DIAMOND_ADDRESS \"resumeNewDeals()\" --account deployer");
        console.log("");
        console.log("Rollback (points the sixty-one replaced selectors back at the previous facets,");
        console.log("which are still on chain and still work - they are the code running today):");
        console.log("  forge script script/UpgradeEmergencyBrake.s.sol \\");
        console.log("    --sig \"rollback(address,address,address)\" <factory> <jobBoard> <serviceBoard> \\");
        console.log("    --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER --broadcast");
        console.log("  <factory>      =", previousFactory);
        console.log("  <jobBoard>     =", previousJobBoard);
        console.log("  <serviceBoard> =", previousServiceBoard);
    }

    // ════════════════════════════════════════════════════════════════════
    // rollback
    // ════════════════════════════════════════════════════════════════════

    /// Undo, as a command rather than as a paragraph somebody has to
    /// transcribe. Points the sixty-one replaced selectors back at the previous
    /// facets, removes the five added ones, and refuses if the chain is not in
    /// the state that follows this cut -- a rollback that runs against an
    /// unexpected diamond is how one mistake becomes two.
    ///
    /// ⚠️ IT REFUSES WHILE THE BRAKE IS DOWN, AND THAT IS THE POINT. Rolling
    /// back removes `resumeNewDeals()` and `newDealsPausedUntil()`. The old
    /// boards go back to reading the dead bool, so they open -- but the old
    /// FactoryFacet has no gate at all, so the protocol would simply be
    /// unbraked with a timestamp left behind in a slot nothing reads. Harmless
    /// on its face, and still refused: an operator who rolls back DURING an
    /// emergency has un-braked the protocol without meaning to, and would find
    /// out from the accident rather than from this line.
    function rollback(address previousFactory, address previousJobBoard, address previousServiceBoard) external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        require(diamond != address(0), "rollback: DIAMOND_ADDRESS is zero");
        require(
            previousFactory != address(0) && previousJobBoard != address(0) && previousServiceBoard != address(0),
            "rollback: a previous facet is zero"
        );
        require(
            previousFactory.code.length > 0 && previousJobBoard.code.length > 0 && previousServiceBoard.code.length > 0,
            "rollback: a previous facet has no code"
        );

        address currentOwner = _readAddress(diamond, "owner()");
        if (msg.sender == DEFAULT_SENDER) {
            console.log("NOTE: no signer named (--account/--sender absent).");
            console.log("      Ownership is NOT checked in this run. The live run needs:");
            console.log("      --account deployer --sender", currentOwner);
        } else {
            require(currentOwner == msg.sender, "rollback: the signer is not the diamond owner");
        }

        bytes4[] memory facSels = factoryReplaceSelectors();
        bytes4[] memory addSels = factoryAddSelectors();
        bytes4[] memory jobSels = jobBoardReplaceSelectors();
        bytes4[] memory svcSels = serviceBoardReplaceSelectors();

        // This cut must actually have landed here, or the `Remove` element
        // reverts on an unmounted selector and takes the rollback with it.
        assertAddGroupIsMountedEverywhere(addSels, diamond);

        (bool okUntil, bytes memory untilData) = diamond.staticcall(
            abi.encodeWithSelector(FactoryFacet.newDealsPausedUntil.selector)
        );
        require(okUntil && untilData.length >= 32, "rollback: the diamond does not answer newDealsPausedUntil()");
        require(
            abi.decode(untilData, (uint256)) <= block.timestamp,
            "rollback: the brake is DOWN - this would silently un-brake the protocol. Call resumeNewDeals() first, on purpose"
        );

        require(
            assertAllMountedOnOneFacet(facSels, diamond) != previousFactory,
            "rollback: the Factory selectors already point at the facet asked for - nothing to undo"
        );

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut(previousFactory, IDiamondCut.FacetCutAction.Replace, facSels);
        cuts[1] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, addSels);
        cuts[2] = IDiamondCut.FacetCut(previousJobBoard, IDiamondCut.FacetCutAction.Replace, jobSels);
        cuts[3] = IDiamondCut.FacetCut(previousServiceBoard, IDiamondCut.FacetCutAction.Replace, svcSels);

        vm.startBroadcast();
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        assertRouted(facSels, previousFactory, diamond);
        assertRouted(jobSels, previousJobBoard, diamond);
        assertRouted(svcSels, previousServiceBoard, diamond);
        for (uint256 i = 0; i < addSels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(addSels[i]) == address(0),
                "rollback: an added selector is still routed"
            );
        }
        console.log("Rolled back. The marketplace has no brake again, and the boards read the dead bool.");
    }

    // ════════════════════════════════════════════════════════════════════
    // The checks, each with its expected side from somewhere that is not
    // this script
    // ════════════════════════════════════════════════════════════════════

    /// The hand-written lists against solc's own answer to "what does this
    /// facet expose". Set equality in both directions, per facet:
    ///
    ///   * a function a facet implements and this cut does not mount would ship
    ///     dead -- present in the ABI, routed nowhere, discovered by the first
    ///     person whose button did nothing;
    ///   * a selector this cut mounts and the facet does not implement routes
    ///     calls into whatever byte offset happens to be there.
    ///
    /// FactoryFacet is checked as Replace ∪ Add, which is the whole point of
    /// the split: a selector that drifts from one group to the other keeps the
    /// union identical and would still revert the cut on chain. That half is
    /// answered by `assertAllMountedOnOneFacet` and
    /// `assertAddGroupIsUnmountedAnywhere`, whose expected side is the chain.
    function assertListsCoverTheCompiledFacets(
        bytes4[] memory facSels,
        bytes4[] memory addSels,
        bytes4[] memory jobSels,
        bytes4[] memory svcSels
    ) public view {
        _assertSameSet(_concat(facSels, addSels), artifactSelectors(FACTORY_ARTIFACT), "FactoryFacet");
        _assertSameSet(jobSels, artifactSelectors(JOBBOARD_ARTIFACT), "JobBoardFacet");
        _assertSameSet(svcSels, artifactSelectors(SERVICEBOARD_ARTIFACT), "ServiceBoardFacet");
    }

    /// solc's own answer to "what does this facet expose", straight out of the
    /// build artifact. `methodIdentifiers` maps the signature to the four-byte
    /// selector as text, so nothing has to be hashed here.
    function artifactSelectors(string memory artifactPath) public view returns (bytes4[] memory out) {
        string memory json = vm.readFile(artifactPath);
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i = 0; i < sigs.length; i++) {
            out[i] = bytes4(keccak256(bytes(sigs[i])));
        }
    }

    /// Every selector must be routed TODAY, and all of them to the same
    /// address. An unmounted one belongs in `Add`, not in `Replace`, and
    /// putting it in the wrong group reverts the whole cut. Returns the facet
    /// they are on.
    function assertAllMountedOnOneFacet(bytes4[] memory sels, address diamond)
        public view returns (address host)
    {
        host = IDiamondLoupe(diamond).facetAddress(sels[0]);
        require(
            host != address(0),
            "pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert"
        );
        for (uint256 i = 1; i < sels.length; i++) {
            address where = IDiamondLoupe(diamond).facetAddress(sels[i]);
            require(
                where != address(0),
                "pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert"
            );
            require(
                where == host,
                "pre-flight: a Replace group is spread over more than one facet - this cut assumes one each"
            );
        }
    }

    /// The other direction of the same question: a facet being replaced must
    /// not hold a selector this cut does not carry. One left behind would keep
    /// pointing at an address whose code no longer implements it -- a live
    /// button answering with whatever that old byte offset happens to be.
    function assertNothingIsLeftBehind(bytes4[] memory sels, address previousFacet, address diamond)
        public view
    {
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousFacet).length == sels.length,
            "pre-flight: a facet being replaced holds a different number of selectors than this cut carries"
        );
    }

    /// ⚠️ THE HALF THAT IS EASIEST TO GET WRONG. `Add` reverts on a selector
    /// already routed, so "not on this facet" is the wrong question -- the right
    /// one is "not routed ANYWHERE in this diamond".
    ///
    /// Asked of the loupe, over the whole diamond, and NOT of this script's own
    /// lists: a stand that built "what is mounted" out of
    /// `factoryReplaceSelectors()` would agree with itself no matter which
    /// group a selector was filed under. That is the fourth way to be fooled by
    /// a measurement, and on 16 August it cost a whole cut.
    function assertAddGroupIsUnmountedAnywhere(bytes4[] memory addSels, address diamond) public view {
        for (uint256 i = 0; i < addSels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(addSels[i]) == address(0),
                "pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert"
            );
        }
    }

    /// The rollback's mirror of the above: a diamond this cut never landed on
    /// has nothing to undo, and the `Remove` element would revert on it.
    function assertAddGroupIsMountedEverywhere(bytes4[] memory addSels, address diamond) public view {
        for (uint256 i = 0; i < addSels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(addSels[i]) != address(0),
                "rollback: an added selector is not mounted - this cut did not land here"
            );
        }
    }

    /// Asked of the DOOR rather than of the loupe. A diamond that already has
    /// this cut answers `newDealsPausedUntil()`; one that does not reverts with
    /// "Diamond: function not found". Running the cut twice would revert inside
    /// `Add` anyway, but it would revert AFTER three facets have been paid for,
    /// and the message would be about a selector rather than about the fact
    /// that the operator is repeating himself.
    function assertTheBrakeIsNotThereYet(address diamond) public view {
        (bool ok, ) = diamond.staticcall(
            abi.encodeWithSelector(FactoryFacet.newDealsPausedUntil.selector)
        );
        require(!ok, "pre-flight: the diamond already answers newDealsPausedUntil() - this cut has already landed");
    }

    function assertRouted(bytes4[] memory sels, address expected, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                "post-flight: a selector did not land on the new facet"
            );
        }
    }

    /// What proves the brake is RUNNING and not merely mounted. Three separate
    /// claims, told apart from each other on purpose:
    ///
    ///   1. `newDealsPausedUntil()` answers, and answers ZERO. Answering at all
    ///      says the `Add` landed. Answering zero says the appended field came
    ///      down on an UNTOUCHED slot -- a field that had quietly aliased an
    ///      occupied one would answer with the fee floor, or the max pending
    ///      requests, or whatever else lives there, and the diamond would be
    ///      braked until the year 1970-plus-that-number.
    ///
    ///   2. `NEW_DEALS_PAUSE_DURATION()` answers 72 hours -- compared against
    ///      this script's own literal, which is a different source from the
    ///      facet's.
    ///
    ///   3. `pauseNewDeals()` REFUSES this script. Called by an address that is
    ///      not the owner -- and the script contract is not -- it must come back
    ///      with `NotOwner`. A diamond that never got this cut comes back with
    ///      "Diamond: function not found" instead, and the two are told apart
    ///      here rather than being read as one "it reverted".
    ///
    /// All three are staticcalls, so the probe cannot press the brake even if
    /// the code behind the selector is not the code this script deployed.
    function assertTheBrakeIsUpAndRefusesAStranger(address diamond) public view {
        (bool okUntil, bytes memory untilData) = diamond.staticcall(
            abi.encodeWithSelector(FactoryFacet.newDealsPausedUntil.selector)
        );
        require(okUntil && untilData.length >= 32, "post-flight: newDealsPausedUntil() does not answer - the Add did not land");
        require(
            abi.decode(untilData, (uint256)) == 0,
            "post-flight: newDealsPausedUntil() is not zero on a diamond that has never been braked - the appended field is aliasing an occupied slot"
        );

        (bool okDur, bytes memory durData) = diamond.staticcall(
            abi.encodeWithSignature("NEW_DEALS_PAUSE_DURATION()")
        );
        require(okDur && durData.length >= 32, "post-flight: NEW_DEALS_PAUSE_DURATION() does not answer");
        require(
            abi.decode(durData, (uint256)) == EXPECTED_PAUSE_DURATION,
            "post-flight: the facet's pause duration is not the 72 hours this cut was written for"
        );

        (bool okPress, bytes memory pressRet) = diamond.staticcall(
            abi.encodeWithSelector(FactoryFacet.pauseNewDeals.selector)
        );
        require(!okPress, "post-flight: pauseNewDeals() accepted a caller that is not the owner");
        require(
            pressRet.length >= 4 && bytes4(pressRet) == FactoryFacet.NotOwner.selector,
            "post-flight: pauseNewDeals() did not refuse with NotOwner - the selector may be unrouted, or behind other code"
        );
    }

    function totalRoutedSelectors(address diamond) public view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(diamond).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    // ════════════════════════════════════════════════════════════════════
    // Storage continuity
    // ════════════════════════════════════════════════════════════════════

    struct StorageSnapshot {
        uint256 totalJobs;
        uint256 totalServices;
        uint256 totalRequests;
        uint256 feeBps;
        uint256 feeFloor;
        uint256 maxPendingRequests;
        address feeRecipient;
        address agreementDeployer;
    }

    /// The factory namespace and both board counters, read through the diamond,
    /// before and after.
    ///
    /// This cut APPENDS one word to `FactoryStorage.Layout`, and these eight
    /// readings are what stands between an append and a renumbering. The
    /// storage gates (`script/check-storage-structs.sh`) catch a moved field in
    /// the source; nothing in the source catches a facet compiled from a
    /// layout that had already moved. `feeFloor` and `maxPendingRequests` are
    /// in the snapshot on purpose -- they are the two words nearest the new
    /// field, and the first two an off-by-one would land on.
    function snapshotFactoryAndBoards(address diamond) public view returns (StorageSnapshot memory s) {
        FactoryFacet fac = FactoryFacet(diamond);
        s.feeBps             = fac.getFeeBps();
        s.feeFloor           = fac.getFeeFloor();
        s.maxPendingRequests = fac.getMaxPendingRequests();
        s.feeRecipient       = fac.getFeeRecipient();
        s.agreementDeployer  = fac.getAgreementDeployer();
        s.totalJobs          = JobBoardFacet(diamond).totalJobs();
        s.totalServices      = ServiceBoardFacet(diamond).totalServices();
        s.totalRequests      = ServiceBoardFacet(diamond).totalRequests();
    }

    function assertStorageUnmoved(
        StorageSnapshot memory beforeCut,
        StorageSnapshot memory afterCut
    ) public pure {
        require(beforeCut.feeBps == afterCut.feeBps, "post-flight: the fee rate moved across the cut");
        require(beforeCut.feeFloor == afterCut.feeFloor, "post-flight: the fee floor moved across the cut");
        require(
            beforeCut.maxPendingRequests == afterCut.maxPendingRequests,
            "post-flight: the max pending requests moved across the cut"
        );
        require(
            beforeCut.feeRecipient == afterCut.feeRecipient,
            "post-flight: the fee recipient moved across the cut"
        );
        require(
            beforeCut.agreementDeployer == afterCut.agreementDeployer,
            "post-flight: the agreement deployer moved across the cut"
        );
        require(beforeCut.totalJobs == afterCut.totalJobs, "post-flight: the job count moved across the cut");
        require(
            beforeCut.totalServices == afterCut.totalServices,
            "post-flight: the service count moved across the cut"
        );
        require(
            beforeCut.totalRequests == afterCut.totalRequests,
            "post-flight: the request count moved across the cut"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // small helpers
    // ════════════════════════════════════════════════════════════════════

    function _assertSameSet(bytes4[] memory mine, bytes4[] memory theirs, string memory what) internal pure {
        require(
            mine.length == theirs.length,
            string.concat("pre-flight: ", what, " - this cut and the compiled facet disagree on how many functions it has")
        );
        for (uint256 i = 0; i < theirs.length; i++) {
            bool found;
            for (uint256 j = 0; j < mine.length; j++) {
                if (theirs[i] == mine[j]) { found = true; break; }
            }
            require(found, string.concat("pre-flight: ", what, " implements a function this cut does not mount"));
        }
        for (uint256 i = 0; i < mine.length; i++) {
            bool found;
            for (uint256 j = 0; j < theirs.length; j++) {
                if (mine[i] == theirs[j]) { found = true; break; }
            }
            require(found, string.concat("pre-flight: this cut mounts a selector ", what, " does not implement"));
        }
    }

    function _assertDisjoint(bytes4[] memory a, bytes4[] memory b) internal pure {
        for (uint256 i = 0; i < a.length; i++) {
            for (uint256 j = 0; j < b.length; j++) {
                require(
                    a[i] != b[j],
                    "pre-flight: the same selector is in both Replace and Add - one of the two would revert"
                );
            }
        }
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }

    function _readAddress(address target, string memory sig) internal view returns (address out) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && ret.length == 32, string.concat("upgrade: the diamond did not answer ", sig));
        out = abi.decode(ret, (address));
    }
}
