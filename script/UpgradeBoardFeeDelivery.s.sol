// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// UpgradeBoardFeeDelivery.s.sol
//
// A REFUND MUST NOT WAIT ON A THIRD PARTY — one diamondCut, four elements:
// three REPLACE groups (JobBoardFacet, ServiceBoardFacet, FactoryFacet) and
// one ADD group of two selectors.
//
// WHAT IS WRONG TODAY. Six board paths hand out custodied USDC and push the
// protocol's fee to `feeRecipient` in the same transaction, under a hard
// `require`. Four of them are the paths a person uses to GET THEIR MONEY BACK:
//   cancelJob                    src/facets/JobBoardFacet.sol
//   rejectRequest                src/facets/ServiceBoardFacet.sol
//   cancelRequest                src/facets/ServiceBoardFacet.sol
//   the supersede loop inside acceptRequest
// and two more start a deal with money already locked in the diamond
// (acceptApplicant, acceptRequest).
//
// USDC keeps a blacklist and its `transfer` REVERTS on a blacklisted receiver.
// So one dollar owed to an address the person never chose decides whether tens
// of dollars belonging to that person come out at all. Measured on Base Sepolia
// on 25 August 2026: job #3 holds 36.19 USDC of budget plus 1.81 USDC of held
// fee, and cancelling it pushes a 1.00 USDC floor to the treasury first. If
// that push ever fails, the 36.19 does not move — and neither does anyone
// else's, because the same line stands on every board refund.
//
// This is not a hypothetical the code was unaware of. `src/Treasury.sol` made
// its OUTGOING payments pull-based FOR THIS EXACT REASON and says so in its own
// header; `ArbiterRegistryFacet` books the dispute fee's treasury slice instead
// of pushing it, with the comment "a blocked feeRecipient would otherwise drop
// every dispute". The inflow is the one place that never got the protection.
//
// WHAT THIS CUT SHIPS.
//
//   the rule       `FactoryStorage.settleFee` — one implementation, called by
//                  both boards, in the same spirit as `FactoryStorage.quote`.
//                  It pushes the fee exactly as before; if the recipient
//                  refuses (revert OR a `false` return), the amount is added to
//                  `FactoryStorage.undeliveredFee` instead. The person's own
//                  transfer already happened by then and is not rolled back.
//
//   the accounting swallowing the refusal was the one outcome ruled out from
//                  the start: the fee is protocol revenue, and "did not go
//                  through, never mind" is a leak no balance would ever show.
//                  The boards emit `FeeCollected` when it arrived and a new
//                  `FeeDeferred` when it did not — deliberately NOT the same
//                  event, because `FeeCollected` is what the subgraph turns
//                  into protocol income and this dollar has not arrived.
//
//   the way back   `FactoryFacet.getUndeliveredFees()` so the debt is visible
//                  and `FactoryFacet.withdrawUndeliveredFees()` so it can be
//                  taken. Both new; both in the ADD group. The pull is open to
//                  anyone and can only pay `FactoryStorage.feeRecipient` — the
//                  same shape, and the same argument, as
//                  `ArbiterRegistryFacet.withdrawTreasurySlice()`.
//
// WHAT THIS CUT DELIBERATELY DOES NOT CHANGE. `mintService` /
// `mintServiceWithPermit` pay the anti-spam floor straight from the executor's
// wallet to `feeRecipient`, never through the diamond, and so do
// `deployAgreement` / `deployAndFund` for a direct hire. A refusal there drops
// the whole call — and that is the right answer: the payer keeps his money,
// nothing is locked, and there is nothing to release. Turning those into a debt
// would have the protocol book revenue for a listing that does not exist.
//
// ⚠️ THIS CUT BOTH REPLACES AND ADDS, WHICH IS THE DANGEROUS SHAPE. `Replace`
// reverts "Diamond: selector not found" on a selector that is not mounted;
// `Add` reverts "Diamond: selector exists" on one that is. Either drops the
// WHOLE cut in one live transaction, after three facets have been paid for. A
// cut that files a selector under the wrong group is therefore not a cosmetic
// mistake — and unlike the previous two cuts, this one can meet BOTH halves of
// the pair.
//
// The claim is "fifty-nine go in Replace, exactly two go in Add", and it is not
// taken on trust in either direction:
//
//   * the expected side comes from the BUILD ARTIFACTS — solc's own
//     `methodIdentifiers` for each of the three facets, read out of
//     out/<Facet>.sol/<Facet>.json — not from the hand-written lists in this
//     file. A function a facet gained and this cut does not mount stops the run;
//   * the actual side comes from the LIVE CHAIN, `facetAddress(sel)` through
//     the loupe, in the pre-flight below. The two Add selectors are checked
//     against the WHOLE diamond, not against one facet: a selector already
//     routed anywhere is a selector `Add` will revert on.
//
// Neither side is derived from the other. The offline twin of the same
// comparison lives in test/BoardFeeDeliveryUpgrade.t.sol and is fed by
// test/fixtures/chain-2026-08-25-boards-fee-selectors.json, a census read off
// Base Sepolia (13 facets, 214 routed selectors; 13 / 25 / 21 on the three
// facets this cut touches).
//
// The storage layout is APPENDED to, never reordered: one new `uint256` at the
// end of `FactoryStorage.Layout`. Zero there means "nothing is owed", which is
// exactly the state of the live diamond on the day this lands. The pre-flight
// and post-flight read the same facts about both boards across the cut and
// refuse if any of them moved.
//
// The diamond address comes from the environment and is never hardcoded.
//
// Usage (dry run — always this one first, it sends no transaction):
//   forge script script/UpgradeBoardFeeDelivery.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL
//
// Usage (live):
//   forge script script/UpgradeBoardFeeDelivery.s.sol \
//     --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER \
//     --broadcast --verify -vvv
// ============================================================

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {FactoryFacet, FactoryStorage} from "../src/FactoryFacet.sol";
import {JobBoardFacet} from "../src/facets/JobBoardFacet.sol";
import {ServiceBoardFacet} from "../src/facets/ServiceBoardFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

contract UpgradeBoardFeeDelivery is Script {

    /// Build artifacts this script holds its own selector lists against.
    /// Read through `vm.readFile`; `./out` is already in `fs_permissions`.
    string internal constant JOBBOARD_ARTIFACT = "out/JobBoardFacet.sol/JobBoardFacet.json";
    string internal constant SERVICEBOARD_ARTIFACT = "out/ServiceBoardFacet.sol/ServiceBoardFacet.json";
    string internal constant FACTORY_ARTIFACT = "out/FactoryFacet.sol/FactoryFacet.json";

    /// Named by the census fixture, and compared against by the offline stand
    /// rather than against a literal there. The trap worth catching is not "the
    /// census is stale" but "an old census was reused for a NEW script".
    function scriptPath() public pure returns (string memory) {
        return "script/UpgradeBoardFeeDelivery.s.sol";
    }

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

        bytes4[] memory jobSels = jobBoardReplaceSelectors();
        bytes4[] memory svcSels = serviceBoardReplaceSelectors();
        bytes4[] memory facSels = factoryReplaceSelectors();
        bytes4[] memory addSels = factoryAddSelectors();

        // The hand-written lists against solc's own output, both ways.
        assertListsCoverTheCompiledFacets(jobSels, svcSels, facSels, addSels);

        // Replace groups: every one of them must be mounted TODAY, and each
        // group all on one facet, or `Replace` reverts and takes the cut.
        address previousJobBoard = assertAllMountedOnOneFacet(jobSels, diamond);
        address previousServiceBoard = assertAllMountedOnOneFacet(svcSels, diamond);
        address previousFactory = assertAllMountedOnOneFacet(facSels, diamond);
        require(
            previousJobBoard != previousServiceBoard
                && previousJobBoard != previousFactory
                && previousServiceBoard != previousFactory,
            "pre-flight: two of the three groups sit on the same facet - this cut assumes three"
        );

        // And each facet must expose nothing else, or the cut leaves a selector
        // pointing at an address that no longer implements it.
        assertNothingIsLeftBehind(jobSels, previousJobBoard, diamond);
        assertNothingIsLeftBehind(svcSels, previousServiceBoard, diamond);
        assertNothingIsLeftBehind(facSels, previousFactory, diamond);

        // Add group: mounted NOWHERE in the whole diamond, not merely absent
        // from FactoryFacet. `Add` reverts on a selector routed anywhere.
        assertAddGroupIsUnmountedAnywhere(addSels, diamond);

        uint256 selectorsBefore = totalRoutedSelectors(diamond);
        uint256 facetsBefore    = IDiamondLoupe(diamond).facetAddresses().length;
        StorageSnapshot memory beforeCut = snapshotBoards(diamond);

        console.log("=== UpgradeBoardFeeDelivery: pre-flight ===");
        console.log("Diamond:                     ", diamond);
        console.log("Owner:                       ", currentOwner);
        console.log("Current JobBoardFacet:       ", previousJobBoard);
        console.log("Current ServiceBoardFacet:   ", previousServiceBoard);
        console.log("Current FactoryFacet:        ", previousFactory);
        console.log("Facets BEFORE cut:           ", facetsBefore);
        console.log("Routed selectors BEFORE cut: ", selectorsBefore);
        console.log("Replace (JobBoard):          ", jobSels.length);
        console.log("Replace (ServiceBoard):      ", svcSels.length);
        console.log("Replace (Factory):           ", facSels.length);
        console.log("Add     (Factory, new):      ", addSels.length);
        console.log("Jobs on the board:           ", beforeCut.totalJobs);
        console.log("Services on the board:       ", beforeCut.totalServices);
        console.log("Requests on the board:       ", beforeCut.totalRequests);
        console.log("Fee held under open jobs:    ", beforeCut.jobFeeHeldSum);
        console.log("Fee recipient:               ", beforeCut.feeRecipient);
        console.log("");

        // ── The cut ────────────────────────────────────────────────────────
        vm.startBroadcast();
        JobBoardFacet jobBoardFacet = new JobBoardFacet();
        ServiceBoardFacet serviceBoardFacet = new ServiceBoardFacet();
        FactoryFacet factoryFacet = new FactoryFacet();
        IDiamondCut(diamond).diamondCut(
            buildCuts(address(jobBoardFacet), address(serviceBoardFacet), address(factoryFacet)),
            address(0),
            ""
        );
        vm.stopBroadcast();

        console.log("New JobBoardFacet:    ", address(jobBoardFacet));
        console.log("New ServiceBoardFacet:", address(serviceBoardFacet));
        console.log("New FactoryFacet:     ", address(factoryFacet));
        console.log("");

        // ── Post-flight: read the result back, do not assume it ────────────
        console.log("=== Post-flight ===");
        assertRouted(jobSels, address(jobBoardFacet), diamond);
        assertRouted(svcSels, address(serviceBoardFacet), diamond);
        assertRouted(facSels, address(factoryFacet), diamond);
        assertRouted(addSels, address(factoryFacet), diamond);
        console.log("All fifty-nine replaced selectors and both new ones land on the new facets.");

        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(jobBoardFacet)).length == jobSels.length,
            "post-flight: the new JobBoardFacet holds a different number of selectors than were replaced"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(serviceBoardFacet)).length == svcSels.length,
            "post-flight: the new ServiceBoardFacet holds a different number of selectors than were replaced"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(address(factoryFacet)).length == facSels.length + addSels.length,
            "post-flight: the new FactoryFacet does not hold the replaced selectors plus the two new ones"
        );
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousJobBoard).length == 0
                && IDiamondLoupe(diamond).facetFunctionSelectors(previousServiceBoard).length == 0
                && IDiamondLoupe(diamond).facetFunctionSelectors(previousFactory).length == 0,
            "post-flight: an old facet still holds selectors - a Replace did not move all of them"
        );

        assertStorageContinuity(beforeCut, snapshotBoards(diamond));
        console.log("Storage continuity OK: jobs, services, requests, held fees and the fee recipient are where they were.");

        assertTheDebtLedgerAnswersAndIsEmpty(diamond);
        console.log("Smoke: getUndeliveredFees() answers, and it answers zero - nothing was owed before this cut existed.");

        uint256 selectorsAfter = totalRoutedSelectors(diamond);
        uint256 facetsAfter    = IDiamondLoupe(diamond).facetAddresses().length;
        require(
            selectorsAfter == selectorsBefore + addSels.length,
            "post-flight: the routed-selector count moved by something other than the Add group"
        );
        require(
            facetsAfter == facetsBefore,
            "post-flight: the facet count moved - the old facets should have been emptied, not unmounted"
        );
        console.log("Facets AFTER cut:            ", facetsAfter);
        console.log("Routed selectors AFTER cut:  ", selectorsAfter);
        console.log("");

        console.log("A refund no longer waits on the fee recipient.");
        console.log("");
        console.log("Rollback (points the fifty-nine replaced selectors back at the previous facets,");
        console.log("which are still on chain and still work - they are the code running today):");
        console.log("  forge script script/UpgradeBoardFeeDelivery.s.sol \\");
        console.log("    --sig \"rollback(address,address,address)\" <jobBoard> <serviceBoard> <factory> \\");
        console.log("    --rpc-url $BASE_SEPOLIA_RPC_URL --account deployer --sender $OWNER --broadcast");
        console.log("  <jobBoard>     =", previousJobBoard);
        console.log("  <serviceBoard> =", previousServiceBoard);
        console.log("  <factory>      =", previousFactory);
        console.log("");
        console.log("WARNING: rolling back REMOVES the two new selectors as well, and any fee booked as");
        console.log("owed while the new code was live stays in FactoryStorage.undeliveredFee with no");
        console.log("function left to pay it out. Roll back only if nothing was ever deferred - the");
        console.log("rollback below refuses when something was.");
    }

    /// Undo, as a command rather than as a paragraph somebody has to
    /// transcribe. Points the fifty-nine replaced selectors back at the
    /// previous facets, removes the two added ones, and refuses if the chain is
    /// not in the state that follows this cut — a rollback that runs against an
    /// unexpected diamond is how one mistake becomes two.
    function rollback(address previousJobBoard, address previousServiceBoard, address previousFactory) external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        require(diamond != address(0), "rollback: DIAMOND_ADDRESS is zero");
        require(
            previousJobBoard != address(0) && previousServiceBoard != address(0) && previousFactory != address(0),
            "rollback: a previous facet is zero"
        );
        require(
            previousJobBoard.code.length > 0 && previousServiceBoard.code.length > 0 && previousFactory.code.length > 0,
            "rollback: a previous facet has no code"
        );

        // The one thing a rollback here can destroy: money already booked as
        // owed. Removing `withdrawUndeliveredFees` would leave it on the
        // diamond with nothing able to pay it out.
        (bool okOwed, bytes memory owedData) = diamond.staticcall(
            abi.encodeWithSelector(FactoryFacet.getUndeliveredFees.selector)
        );
        require(okOwed && owedData.length >= 32, "rollback: the diamond does not answer getUndeliveredFees()");
        require(
            abi.decode(owedData, (uint256)) == 0,
            "rollback: a fee is booked as owed - push it with withdrawUndeliveredFees() first, or it becomes unreachable"
        );

        bytes4[] memory jobSels = jobBoardReplaceSelectors();
        bytes4[] memory svcSels = serviceBoardReplaceSelectors();
        bytes4[] memory facSels = factoryReplaceSelectors();
        bytes4[] memory addSels = factoryAddSelectors();

        require(
            assertAllMountedOnOneFacet(jobSels, diamond) != previousJobBoard,
            "rollback: the JobBoard selectors already point at the facet asked for - nothing to undo"
        );

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut(previousJobBoard, IDiamondCut.FacetCutAction.Replace, jobSels);
        cuts[1] = IDiamondCut.FacetCut(previousServiceBoard, IDiamondCut.FacetCutAction.Replace, svcSels);
        cuts[2] = IDiamondCut.FacetCut(previousFactory, IDiamondCut.FacetCutAction.Replace, facSels);
        cuts[3] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, addSels);

        vm.startBroadcast();
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");
        vm.stopBroadcast();

        assertRouted(jobSels, previousJobBoard, diamond);
        assertRouted(svcSels, previousServiceBoard, diamond);
        assertRouted(facSels, previousFactory, diamond);
        for (uint256 i = 0; i < addSels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(addSels[i]) == address(0),
                "rollback: an added selector is still routed"
            );
        }
        console.log("Rolled back. The refund waits on the fee recipient again.");
    }

    // ════════════════════════════════════════════════════════════════════
    // CHECKS — public so test/BoardFeeDeliveryUpgrade.t.sol can call them
    // against a locally built diamond, not only through run() on a live chain.
    // ════════════════════════════════════════════════════════════════════

    /// Every hand-written list against solc's `methodIdentifiers`, in both
    /// directions and for all three facets. Set equality, not a count: a count
    /// agrees on a swap.
    ///
    /// FactoryFacet is checked as Replace ∪ Add, which is the whole point of
    /// the split: a selector that drifts from one group to the other keeps the
    /// union identical and would still revert the cut on chain. That half is
    /// answered by `assertAllMountedOnOneFacet` and
    /// `assertAddGroupIsUnmountedAnywhere`, whose expected side is the chain.
    function assertListsCoverTheCompiledFacets(
        bytes4[] memory jobSels,
        bytes4[] memory svcSels,
        bytes4[] memory facSels,
        bytes4[] memory addSels
    ) public view {
        _assertSameSet(jobSels, artifactSelectors(JOBBOARD_ARTIFACT), "JobBoardFacet");
        _assertSameSet(svcSels, artifactSelectors(SERVICEBOARD_ARTIFACT), "ServiceBoardFacet");
        _assertSameSet(_concat(facSels, addSels), artifactSelectors(FACTORY_ARTIFACT), "FactoryFacet");

        // And the two groups must be disjoint, or one of the two FacetCut
        // entries reverts by construction.
        for (uint256 i = 0; i < facSels.length; i++) {
            for (uint256 j = 0; j < addSels.length; j++) {
                require(
                    facSels[i] != addSels[j],
                    "pre-flight: a selector is in both the Factory Replace group and the Add group"
                );
            }
        }
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
                "pre-flight: a Replace group is spread over more than one facet - this cut assumes one facet per group"
            );
        }
    }

    /// The other direction of the same question: the facet being replaced must
    /// not hold a selector this cut does not carry. One left behind would keep
    /// pointing at an address whose code no longer implements it — a live
    /// button answering with whatever that old byte offset happens to be.
    function assertNothingIsLeftBehind(bytes4[] memory sels, address previousFacet, address diamond)
        public view
    {
        require(
            IDiamondLoupe(diamond).facetFunctionSelectors(previousFacet).length == sels.length,
            "pre-flight: a facet being replaced holds a different number of selectors than this cut carries"
        );
    }

    /// ⚠️ THE HALF THE PREVIOUS TWO CUTS COULD NOT GET WRONG. `Add` reverts on
    /// a selector already routed, so "not on FactoryFacet" is the wrong
    /// question — the right one is "not routed ANYWHERE in this diamond".
    ///
    /// Asked of the loupe, over the whole diamond, and NOT of this script's own
    /// lists: a stand that built "what is mounted" out of `replaceSelectors()`
    /// would agree with itself no matter which group a selector was filed under.
    /// That is the fourth way to be fooled by a measurement, and it cost a whole
    /// cut once.
    function assertAddGroupIsUnmountedAnywhere(bytes4[] memory addSels, address diamond) public view {
        for (uint256 i = 0; i < addSels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(addSels[i]) == address(0),
                "pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert"
            );
        }
    }

    function assertRouted(bytes4[] memory sels, address expected, address diamond) public view {
        for (uint256 i = 0; i < sels.length; i++) {
            require(
                IDiamondLoupe(diamond).facetAddress(sels[i]) == expected,
                "post-flight: a selector did not land on the new facet"
            );
        }
    }

    /// Functional smoke, and the only one that says the cut did what it was
    /// for: the debt ledger answers at all, and it answers zero. A non-zero
    /// answer on a diamond that has never run this code would mean the new
    /// field reads somebody else's slot — the layout moved, and the cut has to
    /// be undone before anything touches money.
    function assertTheDebtLedgerAnswersAndIsEmpty(address diamond) public view {
        (bool ok, bytes memory ret) = diamond.staticcall(
            abi.encodeWithSelector(FactoryFacet.getUndeliveredFees.selector)
        );
        require(ok && ret.length >= 32, "post-flight: the diamond does not answer getUndeliveredFees()");
        require(
            abi.decode(ret, (uint256)) == 0,
            "post-flight: the debt ledger is not empty on a diamond that never deferred a fee - the layout may have shifted"
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
        uint256 jobFeeHeldSum;
        address feeRecipient;
        address firstJobClient;
    }

    /// Six readings of the two boards taken through the diamond, before and
    /// after.
    ///
    /// `jobFeeHeldSum` and `feeRecipient` are the two this particular cut has
    /// to earn: the fee ledger is what the new code reads and writes, and
    /// `FactoryStorage` is the layout that grew. A new field appended in the
    /// wrong place would read a live one, and a board that had silently lost
    /// its held fees would look, from every other angle, exactly healthy.
    function snapshotBoards(address diamond) public view returns (StorageSnapshot memory s) {
        JobBoardFacet jb = JobBoardFacet(diamond);
        s.totalJobs = jb.totalJobs();
        for (uint256 i = 0; i < s.totalJobs; i++) s.jobFeeHeldSum += jb.getJobFeeHeld(i);
        if (s.totalJobs > 0) s.firstJobClient = jb.getJob(0).client;

        ServiceBoardFacet sb = ServiceBoardFacet(diamond);
        s.totalServices = sb.totalServices();
        s.totalRequests = sb.totalRequests();

        s.feeRecipient = FactoryFacet(diamond).getFeeRecipient();
    }

    function assertStorageContinuity(StorageSnapshot memory beforeCut, StorageSnapshot memory afterCut)
        public pure
    {
        require(
            afterCut.totalJobs == beforeCut.totalJobs,
            "post-flight: totalJobs changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.totalServices == beforeCut.totalServices,
            "post-flight: totalServices changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.totalRequests == beforeCut.totalRequests,
            "post-flight: totalRequests changed across the cut - the layout may have shifted"
        );
        require(
            afterCut.jobFeeHeldSum == beforeCut.jobFeeHeldSum,
            "post-flight: the fee held under the open jobs moved across the cut"
        );
        require(
            afterCut.feeRecipient == beforeCut.feeRecipient,
            "post-flight: the fee recipient changed across the cut - FactoryStorage may have shifted"
        );
        require(
            afterCut.firstJobClient == beforeCut.firstJobClient,
            "post-flight: job 0 has a different client across the cut - the layout may have shifted"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // THE CUT
    // ════════════════════════════════════════════════════════════════════

    /// Four elements. Three whole facets move address, and FactoryFacet
    /// additionally gains two functions — so the Add group is its own element
    /// on the same address, because one FacetCut carries one action.
    function buildCuts(address jobBoardFacet, address serviceBoardFacet, address factoryFacet)
        public pure returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut(jobBoardFacet, IDiamondCut.FacetCutAction.Replace, jobBoardReplaceSelectors());
        cuts[1] = IDiamondCut.FacetCut(serviceBoardFacet, IDiamondCut.FacetCutAction.Replace, serviceBoardReplaceSelectors());
        cuts[2] = IDiamondCut.FacetCut(factoryFacet, IDiamondCut.FacetCutAction.Replace, factoryReplaceSelectors());
        cuts[3] = IDiamondCut.FacetCut(factoryFacet, IDiamondCut.FacetCutAction.Add, factoryAddSelectors());
    }

    /// Thirteen, taken from the type rather than typed as literals: a signature
    /// change is then picked up by the compiler instead of by whoever presses
    /// the button. Held against the build artifact in
    /// `assertListsCoverTheCompiledFacets` and against the live chain in
    /// `assertAllMountedOnOneFacet`.
    ///
    /// Two of them changed in this work — `acceptApplicant` and `cancelJob`,
    /// which now settle the fee instead of requiring it. The other eleven are
    /// here because a Replace must carry the facet's whole selector set or
    /// leave the remainder pointing at the old address.
    function jobBoardReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](13);
        sels[0]  = JobBoardFacet.mintJobWithPermit.selector;
        sels[1]  = JobBoardFacet.mintJob.selector;
        sels[2]  = JobBoardFacet.applyForJob.selector;
        sels[3]  = JobBoardFacet.withdrawApplication.selector;
        sels[4]  = JobBoardFacet.acceptApplicant.selector;   // changed
        sels[5]  = JobBoardFacet.cancelJob.selector;         // changed
        sels[6]  = JobBoardFacet.editJob.selector;
        sels[7]  = JobBoardFacet.getJob.selector;
        sels[8]  = JobBoardFacet.getClientJobs.selector;
        sels[9]  = JobBoardFacet.getApplicants.selector;
        sels[10] = JobBoardFacet.totalJobs.selector;
        sels[11] = JobBoardFacet.getOpenJobs.selector;
        sels[12] = JobBoardFacet.getJobFeeHeld.selector;
    }

    /// Twenty-five. Three changed here — `acceptRequest` (its own fee and the
    /// supersede loop's), `rejectRequest` and `cancelRequest`.
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
        sels[8]  = ServiceBoardFacet.acceptRequest.selector;   // changed
        sels[9]  = ServiceBoardFacet.rejectRequest.selector;   // changed
        sels[10] = ServiceBoardFacet.cancelRequest.selector;   // changed
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

    /// Twenty-one — the whole of today's FactoryFacet. None of their behaviour
    /// changed; they are replaced because the facet is redeployed to carry
    /// `FactoryStorage.settleFee` and the two new functions, and a facet's
    /// selectors cannot be split across two addresses.
    function factoryReplaceSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](21);
        sels[0]  = FactoryFacet.initFactory.selector;
        sels[1]  = FactoryFacet.initFeeModel.selector;
        sels[2]  = FactoryFacet.deployAgreement.selector;
        sels[3]  = FactoryFacet.deployAndFund.selector;
        sels[4]  = FactoryFacet.setRegionFee.selector;
        sels[5]  = FactoryFacet.setFeeRecipient.selector;
        sels[6]  = FactoryFacet.setTrustedForwarder.selector;
        sels[7]  = FactoryFacet.setAgreementDeployer.selector;
        sels[8]  = FactoryFacet.setFeeBps.selector;
        sels[9]  = FactoryFacet.setFeeFloor.selector;
        sels[10] = FactoryFacet.setMaxPendingRequests.selector;
        sels[11] = FactoryFacet.getRegionFee.selector;
        sels[12] = FactoryFacet.getAllFees.selector;
        sels[13] = FactoryFacet.getFeeRecipient.selector;
        sels[14] = FactoryFacet.getTrustedForwarder.selector;
        sels[15] = FactoryFacet.getUsdc.selector;
        sels[16] = FactoryFacet.getAgreementDeployer.selector;
        sels[17] = FactoryFacet.quoteFee.selector;
        sels[18] = FactoryFacet.getFeeBps.selector;
        sels[19] = FactoryFacet.getFeeFloor.selector;
        sels[20] = FactoryFacet.getMaxPendingRequests.selector;
    }

    /// The two that do not exist on chain yet, and the only reason this cut has
    /// an Add group at all. Filed here and nowhere else: putting either of them
    /// in a Replace group reverts the whole cut with "Diamond: selector not
    /// found", after three facets have already been paid for.
    ///
    ///   getUndeliveredFees()      0x5efd2908  — the debt is visible
    ///   withdrawUndeliveredFees() 0xc355f7c5  — the debt can be paid
    function factoryAddSelectors() public pure returns (bytes4[] memory sels) {
        sels = new bytes4[](2);
        sels[0] = FactoryFacet.getUndeliveredFees.selector;
        sels[1] = FactoryFacet.withdrawUndeliveredFees.selector;
    }

    // ════════════════════════════════════════════════════════════════════

    function _assertSameSet(bytes4[] memory mine, bytes4[] memory theirs, string memory label) internal pure {
        require(
            mine.length == theirs.length,
            string.concat("pre-flight: ", label, " - this cut and the compiled facet disagree on how many functions it has")
        );
        for (uint256 i = 0; i < theirs.length; i++) {
            bool found;
            for (uint256 j = 0; j < mine.length; j++) {
                if (theirs[i] == mine[j]) { found = true; break; }
            }
            require(found, string.concat("pre-flight: ", label, " implements a function this cut does not mount"));
        }
        for (uint256 i = 0; i < mine.length; i++) {
            bool found;
            for (uint256 j = 0; j < theirs.length; j++) {
                if (mine[i] == theirs[j]) { found = true; break; }
            }
            require(found, string.concat("pre-flight: this cut mounts a selector ", label, " does not implement"));
        }
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }

    function _readAddress(address target, string memory signature) internal view returns (address) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(
            ok && data.length >= 32,
            string.concat(
                "upgrade: ", signature, " is not answered by DIAMOND_ADDRESS -- wrong address? ",
                "(TRUSTED_FORWARDER, USDC_ADDRESS and FEE_RECIPIENT sit in the same .env and also have code)"
            )
        );
        return abi.decode(data, (address));
    }
}
