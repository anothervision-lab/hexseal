// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeGovernanceHandover.s.sol — the diamondCut that
// replaces both arbitration facets and adds two selectors, carrying decisions
// 50, 51 and 52 into the chain.
//
// ⚠️ WHY A STAND AT ALL, WHEN THE SCRIPT HAS A DRY RUN. A dry run proves the
// script survives TODAY'S chain. It cannot prove the script survives the chain
// it will meet at the moment somebody signs, and it cannot be run in CI at all
// — it needs a network and an RPC key. Everything below runs offline, and the
// questions that decide whether the cut lands or reverts are answered from
// sources this file does not own:
//
//   * "do the lists cover the facets" — the expected side is solc's own
//     `methodIdentifiers`, read out of the build artifacts, not the lists in
//     the script;
//   * "is every Replace selector mounted, is anything else on those facets, and
//     are the two Add selectors mounted nowhere" — the expected side is a
//     census read off Base Sepolia and committed as data
//     (test/fixtures/chain-2026-08-27-arbiter-governance-selectors.json).
//
// Neither is derived from the thing being checked. That is the fourth way to be
// fooled by a measurement, and it cost a whole cut once: a
// stand that built "what is mounted on chain" out of the script's own
// `registryReplaceSelectors()` agreed with itself no matter which group a
// selector was filed under.
//
// ⚠️ THIS CUT CAN MEET BOTH HALVES OF THE PAIR. `Replace` reverts "Diamond:
// selector not found" on a selector that is not mounted; `Add` reverts
// "Diamond: selector exists" on one that is. Fifty-five selectors are filed
// under Replace and two under Add on the SAME facet address, so a selector in
// the wrong group drops the whole cut in a single live transaction after two
// facets have already been paid for. Both halves are demonstrated below against
// a real diamond, not asserted.
//
// ⚠️ WHAT THE OFFLINE RIG CANNOT REHEARSE, AND WHY IT IS SAID OUT LOUD. The rig
// is built from TODAY'S source, so its facets already carry the new
// threshold. The script's pre-flight demands that the chain still read the OLD
// number (100 000) before the cut, and on this rig it therefore REFUSES — which
// is itself the check firing, and is tested as such below. The post-cut side of
// the same guard, and its ability to catch "one facet moved and the other did
// not", are tested on the rig directly.

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/Agreement.sol";
import "../src/AgreementDeployer.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/TreasuryLinkFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {MockUSDCB} from "./BoardsFixture.sol";
import {UpgradeGovernanceHandover} from "../script/UpgradeGovernanceHandover.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterSplitRig} from "./ArbiterSplitRig.sol";

/// An accountability facet whose mirrored threshold is still the OLD number —
/// the shape the diamond would be in if the registry half of the cut landed and
/// the accountability half did not. Nothing but a behavioural read can tell:
/// the selector count is identical either way.
contract StaleMirrorFacet {
    function getDaoThresholdMirror() external pure returns (uint256) { return 100_000; }
}

contract GovernanceHandoverUpgradeTest is Test, ArbiterSplitRig {
    UpgradeGovernanceHandover upgrade;
    DeployFull deploy;
    DiamondProxy diamond;
    MockUSDCB usdc;

    address constant ARBITER = address(0xA11CE);
    address constant CHIEF   = address(0xB0B);
    address constant FEE_RECIPIENT = address(0xFEE);

    /// The census, and the things it is held to before it is believed.
    string constant CENSUS_PATH = "test/fixtures/chain-2026-08-27-arbiter-governance-selectors.json";
    address constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;

    /// Read off the chain on 27 August 2026 and written down by a person, so
    /// that a facet which silently grows or loses a function stops here instead
    /// of at the signature.
    uint256 constant CHAIN_FACETS             = 13;

    uint256 constant CHAIN_ROUTED             = 216;
    uint256 constant REGISTRY_SELECTORS       = 55;
    uint256 constant ACCOUNTABILITY_SELECTORS = 35;
    uint256 constant ADDED_SELECTORS          = 2;

    /// ⚠️ WHAT THE FACETS GREW **AFTER** THIS CUT WAS SIGNED — written by hand,
    /// by SIGNATURE TEXT, never taken from the script's own lists.
    ///
    /// This cut was broadcast on 27 August 2026 (three receipts, all
    /// `status: 0x1`, block 46 033 263, in
    /// broadcast/UpgradeGovernanceHandover.s.sol/84532/run-latest.json). Its
    /// lists are a record of a transaction that has already happened and must
    /// never be edited — editing them would make the script lie about it. But
    /// the facets keep growing, and the locks below compare those frozen lists
    /// against TODAY'S compiled ABI. Without naming the growth, they redden on
    /// every later addition and say nothing useful.
    ///
    /// Each entry is held to two things by
    /// test_TheGrowthBeyondThisCutIsRealAndCoversNothingItMounted: it must be in
    /// the facet's ABI today (a stale exemption dies), and it must be in NEITHER
    /// group of this cut (an exemption cannot quietly cover something the cut
    /// did mount).
    ///
    ///   • setDisputeDiscount(uint256) / getDisputeDiscount() —
    ///     29 August 2026: the arbiter vault takes a fixed amount off a dispute
    ///     top-up, and its size is a stored number rather than a constant.
    ///   • withdrawAppealShare(address), getAppealShareOwed(address,address),
    ///     getAppealLedger(address), quoteAppealDeposit(address) —
    ///     17 September 2026, the appeal economics, all four on ArbiterVaultFacet
    ///     (which is half of the pair this cut's registry became);
    ///     settleAppealDebts(uint256) and getAppealDebts() joined them the same day.
    function _grownAfterThisCut() internal pure returns (bytes4[] memory sels) {
        // ⚠️ THE SIZE IS THE LENGTH OF THE LIST DIRECTLY BELOW IT, and it used
        // to be a sum of separately declared allowance constants. Those
        // constants are gone: a number kept apart from the list it sizes is one
        // more thing to keep in step, and keeping it in step by hand is the
        // habit this file was rewritten to break.
        sels = new bytes4[](10);
        sels[0] = bytes4(keccak256("setDisputeDiscount(uint256)"));
        sels[1] = bytes4(keccak256("getDisputeDiscount()"));
        sels[2] = bytes4(keccak256("withdrawAppealShare(address)"));
        sels[3] = bytes4(keccak256("getAppealShareOwed(address,address)"));
        sels[4] = bytes4(keccak256("getAppealLedger(address)"));
        sels[5] = bytes4(keccak256("quoteAppealDeposit(address)"));
        sels[6] = bytes4(keccak256("settleAppealDebts(uint256)"));
        sels[7] = bytes4(keccak256("getAppealDebts()"));
        // And the two of 18 September 2026 on the arbiter registry: item D1's
        // public door for a dead dispute claim, and the read a screen needs now
        // that the appeal quorum moves with the corps.
        sels[8] = bytes4(keccak256("abandonClaim(address)"));
        sels[9] = bytes4(keccak256("getAppealPanel(address)"));
    }

    ///   • getDisputeSubsidy(address) — a bare read of how much of
    ///     a funded top-up came out of the vault. The field belongs to
    ///     ArbiterRegistryFacet, which writes it; the READ sits on the other
    ///     facet because the registry stands 90 bytes under the EIP-170 ceiling.
    function _grownAccountabilityAfterThisCut() internal pure returns (bytes4[] memory sels) {
        // ⚠️ THE SIZE IS THE LENGTH OF THE LIST DIRECTLY BELOW IT, and it used
        // to be a sum of separately declared allowance constants. Those
        // constants are gone: a number kept apart from the list it sizes is one
        // more thing to keep in step, and keeping it in step by hand is the
        // habit this file was rewritten to break.
        sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("getDisputeSubsidy(address)"));
    }

    ///   • notifyWorkHandedIn() — 31 August 2026, and on the DEAL registry,
    ///     which is a different facet from the arbiter registry above despite
    ///     the shared word. `Agreement.markDone()` used to touch the diamond not
    ///     at all, so the transition that starts the two-day auto-approve clock
    ///     -- after which silence hands the executor the whole pot -- was
    ///     invisible from the one address anything watches.
    function _grownDealRegistryAfterThisCut() internal pure returns (bytes4[] memory sels) {
        // ⚠️ THE SIZE IS THE LENGTH OF THE LIST DIRECTLY BELOW IT, and it used
        // to be a sum of separately declared allowance constants. Those
        // constants are gone: a number kept apart from the list it sizes is one
        // more thing to keep in step, and keeping it in step by hand is the
        // habit this file was rewritten to break.
        sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("notifyWorkHandedIn()"));
    }

    ///   • pauseNewDeals() / resumeNewDeals() / newDealsPausedUntil() /
    ///     NEW_DEALS_PAUSE_DURATION() — 3 September 2026, on FactoryFacet,
    ///     which this cut mounts not a single selector of. The marketplace
    ///     gets an emergency stop that lets go by itself after 72 hours
    ///     (decision 17); until it ships, the `whenNotPaused` on nine money
    ///     doors reads a bool nothing has been able to write since 24 June
    ///     2026.
    ///   • MAX_FEE_BPS() — 3 September 2026, on the same FactoryFacet and in
    ///     the same cut as the four above. Item 138: the 20% ceiling on the fee
    ///     rate, which stood as a bare `2_000` in two places and could be read
    ///     from nowhere.
    function _grownFactoryAfterThisCut() internal pure returns (bytes4[] memory sels) {
        // ⚠️ THE SIZE IS THE LENGTH OF THE LIST DIRECTLY BELOW IT, and it used
        // to be a sum of separately declared allowance constants. Those
        // constants are gone: a number kept apart from the list it sizes is one
        // more thing to keep in step, and keeping it in step by hand is the
        // habit this file was rewritten to break.
        sels = new bytes4[](5);
        sels[0] = bytes4(keccak256("pauseNewDeals()"));
        sels[1] = bytes4(keccak256("resumeNewDeals()"));
        sels[2] = bytes4(keccak256("newDealsPausedUntil()"));
        sels[3] = bytes4(keccak256("NEW_DEALS_PAUSE_DURATION()"));
        sels[4] = bytes4(keccak256("MAX_FEE_BPS()"));
    }

    /// Two numbers from a recorded decision, copied here by a person.
    uint256 constant THRESHOLD_BEFORE = 100_000;
    uint256 constant THRESHOLD_AFTER  = 10_000;

    function setUp() public {
        upgrade = new UpgradeGovernanceHandover();
        deploy  = new DeployFull();
        usdc    = new MockUSDCB();
        diamond = _deployPreCutDiamond();
        _initDiamond();
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE INDEPENDENT ORACLES
    // ══════════════════════════════════════════════════════════════════════

    /// The script's hand-written lists against solc's output for each facet. A
    /// function a facet gains and nobody mounts would otherwise ship dead:
    /// present in the ABI, routed nowhere, discovered by the first person whose
    /// button did nothing.
    ///
    /// ⚠️ The growth beyond this cut is handed to the script's own check as if
    /// it were part of the Add groups, and that is the only honest way round:
    /// the check asks "do these lists cover the compiled facet", the compiled
    /// facet has moved on, and the script may not be edited because it has
    /// already run. What keeps the allowance from being a hole is that the three
    /// names are pinned by text and held to two conditions of their own.
    function test_ListsCoverExactlyTheCompiledFacets() public view {
        upgrade.assertListsCoverTheCompiledFacets(
            upgrade.registryReplaceSelectors(),
            _concat(upgrade.registryAddSelectors(), _grownAfterThisCut()),
            _concat(upgrade.accountabilityReplaceSelectors(), _grownAccountabilityAfterThisCut())
        );

        assertEq(upgrade.registryReplaceSelectors().length, REGISTRY_SELECTORS);
        assertEq(upgrade.registryAddSelectors().length, ADDED_SELECTORS);
        assertEq(upgrade.accountabilityReplaceSelectors().length, ACCOUNTABILITY_SELECTORS);
    }

    /// THE PROOF OF THE Replace/Add SPLIT, half one: everything in a Replace
    /// group is mounted on the live chain today, and everything mounted on those
    /// two facets is in a Replace group. Set equality in both directions, per
    /// facet.
    ///
    ///   * nothing in a Replace group is unmounted -> no element belongs in Add;
    ///   * nothing mounted is missing -> no selector is left pointing at a facet
    ///     that no longer implements it.
    function test_EveryReplacedSelectorIsMountedOnTheLiveChainAndNothingElseIs() public view {
        _assertSameSet(
            upgrade.registryReplaceSelectors(),
            _censusAt(".arbiterRegistrySelectors", ".arbiterRegistryCount"),
            "ArbiterRegistry"
        );
        _assertSameSet(
            upgrade.accountabilityReplaceSelectors(),
            _censusAt(".arbiterAccountabilitySelectors", ".arbiterAccountabilityCount"),
            "ArbiterAccountability"
        );
    }

    /// THE PROOF OF THE SPLIT, half two. Both Add selectors must be mounted
    /// NOWHERE in the diamond, which is a question about the whole routed list,
    /// not about ArbiterRegistryFacet: `Add` reverts on a selector routed
    /// anywhere at all.
    function test_BothAddedSelectorsAreMountedNowhereOnTheLiveChain() public view {
        bytes4[] memory whole = _censusAt(".selectors", ".count");
        assertEq(whole.length, CHAIN_ROUTED, "the census does not hold the number of selectors it claims");

        bytes4[] memory added = upgrade.registryAddSelectors();
        for (uint256 i = 0; i < added.length; i++) {
            for (uint256 j = 0; j < whole.length; j++) {
                assertTrue(
                    added[i] != whole[j],
                    "a selector this cut ADDS is already routed on the live chain - it belongs in Replace, and Add would revert"
                );
            }
        }
    }

    /// And the same claim asked of the ARTIFACT rather than of the script: the
    /// compiled ArbiterRegistryFacet must expose exactly two functions the chain
    /// does not have. A third one added later without touching the script would
    /// be caught here rather than by whoever presses the button.
    function test_TheCompiledRegistryGainsExactlyTheTwoSelectorsThisCutAdds() public view {
        // ⚠️ THE PAIR, NOT ONE FILE (16 September 2026). The facet this cut
        // mounted was split into ArbiterRegistryFacet and ArbiterVaultFacet with
        // no signature touched, so "what the compiled registry exposes" is the
        // union of the two — the same set the single facet had. Taught rather
        // than frozen: this test exists to notice a function added later, and a
        // frozen list would stop noticing.
        bytes4[] memory fromArtifact = upgrade.registryFacetAbi();
        bytes4[] memory mounted = _censusAt(".arbiterRegistrySelectors", ".arbiterRegistryCount");

        uint256 unmounted;
        for (uint256 i = 0; i < fromArtifact.length; i++) {
            bool found;
            for (uint256 j = 0; j < mounted.length; j++) {
                if (fromArtifact[i] == mounted[j]) { found = true; break; }
            }
            if (!found) unmounted++;
        }
        assertEq(
            unmounted, ADDED_SELECTORS + _grownAfterThisCut().length,
            "the compiled ArbiterRegistryFacet gains a different number of functions than this cut adds plus what is queued behind it"
        );
    }

    /// The allowance is held to its own two conditions, in its own test so that
    /// a failure names which one broke.
    ///
    /// What disappears from behaviour if this is removed: the allowance above
    /// becomes an unchecked hole — a selector could be dropped out of the cut's
    /// lists and parked here, and the coverage locks would call the cut complete.
    function test_TheGrowthBeyondThisCutIsRealAndCoversNothingItMounted() public view {
        bytes4[] memory grown = _grownAfterThisCut();
        bytes4[] memory regAbi = upgrade.registryFacetAbi(); // the pair — see the note above
        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(_contains(regAbi, grown[i]), "the allowance is stale: no such function in the registry ABI");
            assertFalse(_contains(upgrade.registryReplaceSelectors(), grown[i]), "the allowance covers a selector this cut REPLACED");
            assertFalse(_contains(upgrade.registryAddSelectors(), grown[i]), "the allowance covers a selector this cut ADDED");
        }

        bytes4[] memory grownAcc = _grownAccountabilityAfterThisCut();
        bytes4[] memory accAbi =
            upgrade.artifactSelectors("out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json");
        for (uint256 i = 0; i < grownAcc.length; i++) {
            assertTrue(_contains(accAbi, grownAcc[i]), "the allowance is stale: no such function in the accountability ABI");
            assertFalse(_contains(upgrade.accountabilityReplaceSelectors(), grownAcc[i]), "the allowance covers a selector this cut REPLACED");
        }

        // The deal registry, which this cut does not mount a single selector of
        // -- so the only condition that can be asked of its allowance is that it
        // is not stale, and it is asked against the compiled ABI.
        bytes4[] memory grownDeal = _grownDealRegistryAfterThisCut();
        bytes4[] memory dealAbi =
            upgrade.artifactSelectors("out/RegistryFacet.sol/RegistryFacet.json");
        for (uint256 i = 0; i < grownDeal.length; i++) {
            assertTrue(_contains(dealAbi, grownDeal[i]), "the allowance is stale: no such function in the deal registry ABI");
        }

        // The factory, which this cut does not mount a single selector of
        // either -- so, as with the deal registry, the only condition its
        // allowance can be held to is that it is not stale.
        bytes4[] memory grownFactory = _grownFactoryAfterThisCut();
        bytes4[] memory factoryAbi =
            upgrade.artifactSelectors("out/FactoryFacet.sol/FactoryFacet.json");
        for (uint256 i = 0; i < grownFactory.length; i++) {
            assertTrue(_contains(factoryAbi, grownFactory[i]), "the allowance is stale: no such function in the factory ABI");
        }
    }

    function _contains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) if (haystack[i] == needle) return true;
        return false;
    }

    /// The accountability facet's whole reason for being in this cut, stated as
    /// a claim about its ABI rather than about its behaviour: it gains nothing
    /// and loses nothing. If that ever stops being true, the cut needs an Add or
    /// a Remove group and this file has to change with it.
    /// ⚠️ Held with the growth added to the chain's side rather than by
    /// weakening the comparison: since 29 August 2026 the facet DOES gain one
    /// function beyond this cut, and it is named.
    function test_TheCompiledAccountabilityFacetGainsAndLosesNothing() public view {
        _assertSameSet(
            upgrade.artifactSelectors("out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json"),
            _concat(
                _censusAt(".arbiterAccountabilitySelectors", ".arbiterAccountabilityCount"),
                _grownAccountabilityAfterThisCut()
            ),
            "ArbiterAccountability artifact vs chain"
        );
    }

    /// The census header, before anything is read out of it. The trap worth
    /// catching is not "the census is stale" but "an old census was reused for a
    /// NEW script" — the numbers would look plausible and describe a different
    /// cut.
    function test_TheCensusDescribesThisScriptAndThisDiamond() public view {
        string memory json = vm.readFile(CENSUS_PATH);
        assertEq(
            keccak256(bytes(vm.parseJsonString(json, ".forScript"))),
            keccak256(bytes(upgrade.scriptPath())),
            "this census was taken for a DIFFERENT cut - it does not describe what is being checked"
        );
        assertEq(vm.parseJsonAddress(json, ".diamond"), CENSUS_DIAMOND, "the census was read off a different diamond");
        assertEq(vm.parseJsonUint(json, ".facetCount"), CHAIN_FACETS, "the census disagrees on the facet count");
        assertGt(vm.parseJsonUint(json, ".block"), 0, "the census header has no block number");
        assertGt(bytes(vm.parseJsonString(json, ".takenAt")).length, 0, "the census header has no date");

        // The two numbers the cut is measured against are the CHAIN's, recorded
        // by the same reading that produced the selector lists — not the
        // script's constants restated.
        assertEq(
            vm.parseJsonUint(json, ".arbiterRegistryDaoThreshold"), THRESHOLD_BEFORE,
            "the census does not record the threshold the live registry answers"
        );
        assertEq(
            vm.parseJsonUint(json, ".arbiterAccountabilityDaoThresholdMirror"), THRESHOLD_BEFORE,
            "the census does not record the threshold the live mirror answers"
        );
    }

    /// A third source for the same lists: the from-scratch deploy. If the cut
    /// and the fresh deploy ever disagree about what a facet exposes, one of the
    /// two diamonds is wrong and nothing else would say which.
    /// ⚠️ The growth queued behind this cut is added to THIS cut's side, not
    /// subtracted from DeployFull's: a fresh deploy must mount everything the
    /// facet has today, and this cut mounted everything the facet had in
    /// August. The three names are pinned by text.
    function test_TheCutAndTheFreshDeployMountTheSameSets() public view {
        _assertSameSet(
            _concat(
                _concat(upgrade.registryReplaceSelectors(), upgrade.registryAddSelectors()),
                _grownAfterThisCut()
            ),
            _concat(deploy.arbiterRegistryFacetSelectors(), deploy.arbiterVaultFacetSelectors()),
            "ArbiterRegistry vs DeployFull"
        );
        _assertSameSet(
            _concat(upgrade.accountabilityReplaceSelectors(), _grownAccountabilityAfterThisCut()),
            deploy.arbiterAccountabilityFacetSelectors(),
            "ArbiterAccountability vs DeployFull"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE SHAPE OF THE CUT
    // ══════════════════════════════════════════════════════════════════════

    function test_CutIsTwoReplacesAndOneAdd() public view {
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(0xF00D1), address(0xF00D2));

        assertEq(cuts.length, 3, "the cut must be three elements");

        assertEq(cuts[0].facetAddress, address(0xF00D1));
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace);
        assertEq(cuts[0].functionSelectors.length, REGISTRY_SELECTORS);

        // The Add group lands on the SAME address as the registry Replace group
        // — one FacetCut carries one action, which is the only reason it is a
        // separate element at all.
        assertEq(cuts[1].facetAddress, address(0xF00D1), "the added selectors must land on the new ArbiterRegistryFacet");
        assertTrue(cuts[1].action == IDiamondCut.FacetCutAction.Add);
        assertEq(cuts[1].functionSelectors.length, ADDED_SELECTORS);

        assertEq(cuts[2].facetAddress, address(0xF00D2));
        assertTrue(cuts[2].action == IDiamondCut.FacetCutAction.Replace);
        assertEq(cuts[2].functionSelectors.length, ACCOUNTABILITY_SELECTORS);
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE CUT ITSELF, APPLIED TO A DIAMOND HOLDING A LIVE CORPS AND A VAULT
    // ══════════════════════════════════════════════════════════════════════

    function test_PreFlightPassesAndTheCutLandsWithoutLosingTheCorps() public {
        _seedArbitration();

        bytes4[] memory regSels = upgrade.registryReplaceSelectors();
        bytes4[] memory addSels = upgrade.registryAddSelectors();
        bytes4[] memory accSels = upgrade.accountabilityReplaceSelectors();

        // Pre-flight, exactly as run() calls it — bar the threshold guard, which
        // wants the chain's OLD number and this rig is built from new source.
        // Its refusal here is a test of its own, below.
        // The Add groups carry the growth queued behind this cut for the same
        // reason as in test_ListsCoverExactlyTheCompiledFacets: the compiled
        // facet has moved on and the script may not be edited, having run.
        upgrade.assertListsCoverTheCompiledFacets(
            regSels,
            _concat(addSels, _grownAfterThisCut()),
            _concat(accSels, _grownAccountabilityAfterThisCut())
        );
        address previousRegistry = upgrade.assertAllMountedOnOneFacet(regSels, address(diamond));
        address previousAccountability = upgrade.assertAllMountedOnOneFacet(accSels, address(diamond));
        assertTrue(previousRegistry != previousAccountability, "the two groups sit on the same facet");
        upgrade.assertNothingIsLeftBehind(regSels, previousRegistry, address(diamond));
        upgrade.assertNothingIsLeftBehind(accSels, previousAccountability, address(diamond));
        upgrade.assertAddGroupIsUnmountedAnywhere(addSels, address(diamond));

        uint256 routedBefore = _routed();
        uint256 facetsBefore = IDiamondLoupe(address(diamond)).facetAddresses().length;
        UpgradeGovernanceHandover.StorageSnapshot memory before = upgrade.snapshotArbitration(address(diamond));

        // The scene is only worth running if there is something to lose.
        assertEq(before.arbiterCount, 1, "the seeded corps holds no arbiter");
        assertEq(before.chiefArbiter, CHIEF, "the seeded diamond has no chief");
        assertGt(before.vaultBalance, 0, "the seeded vault is empty");
        uint256 heldBefore = usdc.balanceOf(address(diamond));

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()),
                address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        // ── Post-flight, part one: THE SHAPE, exactly as run() checks it, and
        // checked BEFORE anything below plays the later split out. This is the
        // diamond as Base Sepolia stood the day this cut was signed: one facet
        // per group, the old ones emptied rather than unmounted.
        upgrade.assertRouted(regSels, IDiamondLoupe(address(diamond)).facetAddress(regSels[0]), address(diamond));
        assertEq(usdc.balanceOf(address(diamond)), heldBefore, "the diamond's USDC moved across a cut");
        assertEq(_routed(), routedBefore + ADDED_SELECTORS, "the routed count moved by something other than the Add group");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length, facetsBefore,
            "the facet count moved - the old facets should have been emptied, not unmounted"
        );
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousRegistry).length, 0);
        assertEq(IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousAccountability).length, 0);

        // ⚠️ AND THEN THE SEPTEMBER SPLIT IS PLAYED OUT (16 September 2026).
        // The cut above is the one that was SIGNED: it deploys one
        // `new ArbiterRegistryFacet()` and mounts its whole group on it. It
        // cannot know about a split made three weeks later, and it is not
        // rewritten — it is the record of what went on chain. But everything
        // below reads a MOVED door — getArbiters inside the storage snapshot,
        // getPendingDAOAddress, getDAOAddress — and those are routed at code
        // that no longer implements them until the split lands. That is the
        // chain's real state between the two cuts, so the stand plays the move
        // out, exactly as ArbiterTwoFacetBench._applyTask45MoveAfterLegacyCut
        // does for the August split.
        _replayArbiterVaultSplit(address(diamond));

        // ── Post-flight, part two: THE ANSWERS.
        upgrade.assertStorageContinuity(before, upgrade.snapshotArbitration(address(diamond)));
        upgrade.assertBothThresholdsRead(address(diamond), THRESHOLD_AFTER, "post-flight");
        upgrade.assertTheHandoverDoorAnswersAndIsEmpty(address(diamond));

        // And the doors the cut is FOR actually work afterwards, which no
        // selector count can say. `setDAOAddress` must only propose.
        ArbiterRegistryFacet(address(diamond)).setDAOAddress(address(0xDA0));
        assertEq(
            ArbiterVaultFacet(address(diamond)).getPendingDAOAddress(), address(0xDA0),
            "setDAOAddress did not propose"
        );
        assertEq(
            ArbiterVaultFacet(address(diamond)).getDAOAddress(), address(0),
            "setDAOAddress took effect on the spot - it must only propose"
        );
        vm.prank(address(0xDA0));
        ArbiterRegistryFacet(address(diamond)).acceptDAOAddress();
        assertEq(
            ArbiterVaultFacet(address(diamond)).getDAOAddress(), address(0xDA0),
            "the named successor could not take office from the inside"
        );
    }

    /// The pre-flight has to REFUSE when the chain is not in the shape the cut
    /// assumes. A selector that is not mounted is the realistic way to get
    /// there: a facet that gained a function since the census was taken.
    function test_PreFlightRefusesWhenAReplacedSelectorIsNotMounted() public {
        _unmount(ArbiterVaultFacet.getVaultBalance.selector);

        // ⚠️ Fetched BEFORE the expectation is armed: `vm.expectRevert` arms the
        // NEXT call, and `upgrade.registryReplaceSelectors()` is itself an
        // external call to the script contract.
        bytes4[] memory sels = upgrade.registryReplaceSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert")
        );
        upgrade.assertAllMountedOnOneFacet(sels, address(diamond));
    }

    /// The same refusal for the other facet, so a mistake filed against
    /// ArbiterAccountabilityFacet is not caught only by luck.
    function test_PreFlightRefusesWhenAnAccountabilitySelectorIsNotMounted() public {
        _unmount(ArbiterAccountabilityFacet.getArbiterStanding.selector);

        bytes4[] memory sels = upgrade.accountabilityReplaceSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert")
        );
        upgrade.assertAllMountedOnOneFacet(sels, address(diamond));
    }

    /// The mirror refusal: an Add selector that is already routed.
    function test_PreFlightRefusesWhenAnAddedSelectorIsAlreadyMounted() public {
        _mountOne(ArbiterRegistryFacet.acceptDAOAddress.selector, address(new ArbiterRegistryFacet()));

        bytes4[] memory added = upgrade.registryAddSelectors();
        vm.expectRevert(
            bytes("pre-flight: a selector from Add is already mounted - it belongs in Replace, and Add would revert")
        );
        upgrade.assertAddGroupIsUnmountedAnywhere(added, address(diamond));
    }

    /// And the refusal that catches a facet which grew a function nobody mounted:
    /// the previous facet holds more selectors than the cut carries.
    function test_PreFlightRefusesWhenTheOldFacetHoldsSomethingTheCutDoesNotCarry() public {
        _mountOne(ArbiterRegistryFacet.acceptDAOAddress.selector, _hostOf(ArbiterRegistryFacet.isDaoActive.selector));

        bytes4[] memory sels = upgrade.registryReplaceSelectors();
        address host = _hostOf(ArbiterRegistryFacet.isDaoActive.selector);
        vm.expectRevert(
            bytes("pre-flight: a facet being replaced holds a different number of selectors than this cut carries")
        );
        upgrade.assertNothingIsLeftBehind(sels, host, address(diamond));
    }

    /// The diamond itself refuses, with its own message — proof that the
    /// pre-flight guards a real failure rather than an imagined one.
    function test_ADiamondRejectsAReplaceOfAnUnmountedSelector() public {
        _unmount(ArbiterVaultFacet.getVaultBalance.selector);

        // ⚠️ Built BEFORE the expectation is armed: `vm.expectRevert` arms the
        // NEXT call, and `buildCuts(...)` is itself an external call.
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(
            address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
        );
        vm.expectRevert(bytes("Diamond: selector not found"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }

    /// The other half of the pair, on the same diamond, so that the reason the
    /// two new selectors are filed under Add is demonstrated and not asserted.
    function test_ADiamondRejectsAnAddOfAMountedSelector() public {
        _mountOne(ArbiterRegistryFacet.acceptDAOAddress.selector, address(new ArbiterRegistryFacet()));

        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(
            address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
        );
        vm.expectRevert(bytes("Diamond: selector exists"));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }
    // ⚠️ A TEST WAS REMOVED HERE ON 14 SEPTEMBER 2026, AND WHERE IT WENT
    // MATTERS MORE THAN WHAT IT SAID.
    //
    // `test_AFreshDeployIsExactlyThisCutAheadOfTheLiveChain` asked whether a diamond built from
    // script/DeployFull.s.sol still matches the live chain. That is a real
    // question and it now has exactly one owner:
    // test/DeployFullMatchesChain.t.sol, which asks it against the census read
    // at the CURRENT block.
    //
    // It could never be answered here. This stand's census is a BEFORE picture
    // of one past cut, so the only way to compare today's deploy script with it
    // was "old census, plus a hand-kept allowance for every cut that has landed
    // since". That sum is what turned the ratchet into a budget: on
    // 14 September the sibling of this test in
    // test/JobBoardApplicantGateUpgrade.t.sol was GREEN while a from-scratch
    // deployment would have produced a diamond with no treasury link at all,
    // because the stale census and the nine accumulated allowances added up to
    // exactly what the script built.
    //
    // A stand rehearsing a PAST cut is the wrong place to ask a question about
    // the PRESENT chain, and no amount of care with the allowance fixes that.

    // ══════════════════════════════════════════════════════════════════════
    // THE GUARD THAT WATCHES THE FACET WHOSE SELECTOR COUNT DOES NOT MOVE
    // ══════════════════════════════════════════════════════════════════════

    /// ⚠️ THE ONE THING NO SELECTOR COUNT CAN SAY. ArbiterAccountabilityFacet
    /// ships 35 selectors before this cut and 35 after; only its body changed.
    /// A cut that landed the registry and silently missed the accountability
    /// facet would pass every shape check in this file. This is the scene that
    /// catches it: the registry answers the new threshold, the mirror answers
    /// the old one, and the guard has to say so.
    function test_TheThresholdGuardCatchesAFacetThatDidNotMove() public {
        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()),
                address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );
        // Both agree at this point.
        upgrade.assertBothThresholdsRead(address(diamond), THRESHOLD_AFTER, "post-flight");

        // Now put the mirror back where it was before the cut, and nothing
        // else. Shape unchanged, count unchanged, behaviour wrong.
        bytes4[] memory one = new bytes4[](1);
        one[0] = ArbiterAccountabilityFacet.getDaoThresholdMirror.selector;
        IDiamondCut.FacetCut[] memory stale = new IDiamondCut.FacetCut[](1);
        stale[0] = IDiamondCut.FacetCut(address(new StaleMirrorFacet()), IDiamondCut.FacetCutAction.Replace, one);
        IDiamondCut(address(diamond)).diamondCut(stale, address(0), "");

        assertEq(_routed(), CHAIN_ROUTED + ADDED_SELECTORS, "the sabotage changed the routed count - it is meant not to");

        vm.expectRevert(
            bytes(
                "post-flight: ArbiterAccountabilityFacet.getDaoThresholdMirror() is not the number this phase expects"
                " - the accountability facet's code did not move"
            )
        );
        upgrade.assertBothThresholdsRead(address(diamond), THRESHOLD_AFTER, "post-flight");
    }

    /// The pre-cut half of the same guard, fired on the rig for the reason
    /// stated in this file's header: the rig runs today's source, so it already
    /// answers the NEW number, and the guard that demands the OLD one refuses.
    /// On the live chain the reading is 100 000 and it passes; the value of the
    /// guard is exactly this refusal, on a diamond this cut has already landed
    /// on.
    function test_ThePreFlightThresholdGuardRefusesAChainThisCutAlreadyLandedOn() public {
        vm.expectRevert(
            bytes("pre-flight: ArbiterRegistryFacet.getDaoThreshold() is not the number this phase expects")
        );
        upgrade.assertBothThresholdsRead(address(diamond), THRESHOLD_BEFORE, "pre-flight");
    }

    /// Decision 51's door does not exist before the cut, and answers after it.
    /// Asked of the diamond rather than of the script's list.
    function test_TheHandoverDoorAnswersOnlyAfterTheCut() public {
        (bool okBefore,) = address(diamond).staticcall(
            abi.encodeWithSelector(ArbiterVaultFacet.getPendingDAOAddress.selector)
        );
        assertFalse(okBefore, "getPendingDAOAddress already answers before the cut");

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()),
                address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        // ⚠️ AND THEN THE SEPTEMBER SPLIT IS PLAYED OUT (16 September 2026).
        // The cut above is the one that was SIGNED: it deploys one
        // `new ArbiterRegistryFacet()` and mounts its whole group on it. It
        // cannot know about a split made three weeks later, and it is not
        // rewritten — it is the record of what went on chain. But
        // `getPendingDAOAddress` is one of the twenty-eight that moved, so
        // immediately after that cut it is routed at code which no longer
        // implements it. That is a faithful picture of the chain between the two
        // cuts, not a defect in the stand, and a test that reads a moved door
        // has to play the move out first — the same shape, and the same reason,
        // as ArbiterTwoFacetBench._applyTask45MoveAfterLegacyCut.
        _replayArbiterVaultSplit(address(diamond));

        upgrade.assertTheHandoverDoorAnswersAndIsEmpty(address(diamond));
    }

    /// The rollback path, proved rather than described: the ninety go back to
    /// the facets they came from, the two added ones are removed, and the corps
    /// still reads.
    function test_RollbackRestoresTheShapeAndTheCorpsStillReads() public {
        _seedArbitration();

        bytes4[] memory regSels = upgrade.registryReplaceSelectors();
        bytes4[] memory addSels = upgrade.registryAddSelectors();
        bytes4[] memory accSels = upgrade.accountabilityReplaceSelectors();

        address previousRegistry = upgrade.assertAllMountedOnOneFacet(regSels, address(diamond));
        address previousAccountability = upgrade.assertAllMountedOnOneFacet(accSels, address(diamond));
        uint256 routedBefore = _routed();

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(
                address(new ArbiterRegistryFacet()), address(new ArbiterAccountabilityFacet())
            ),
            address(0),
            ""
        );

        IDiamondCut.FacetCut[] memory undo = new IDiamondCut.FacetCut[](3);
        undo[0] = IDiamondCut.FacetCut(previousRegistry, IDiamondCut.FacetCutAction.Replace, regSels);
        undo[1] = IDiamondCut.FacetCut(previousAccountability, IDiamondCut.FacetCutAction.Replace, accSels);
        undo[2] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, addSels);
        IDiamondCut(address(diamond)).diamondCut(undo, address(0), "");

        upgrade.assertRouted(regSels, previousRegistry, address(diamond));
        upgrade.assertRouted(accSels, previousAccountability, address(diamond));
        assertEq(_routed(), routedBefore, "the rollback did not restore the pre-cut shape");
        assertEq(
            ArbiterVaultFacet(address(diamond)).getArbiters().length, 1,
            "the corps did not survive the rollback"
        );
        assertEq(
            ArbiterVaultFacet(address(diamond)).getChiefArbiter(), CHIEF,
            "the chief did not survive the rollback"
        );
        assertGt(
            ArbiterVaultFacet(address(diamond)).getVaultBalance(), 0,
            "the vault did not survive the rollback"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════

    function _routed() internal view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(diamond)).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
    }

    function _hostOf(bytes4 sel) internal view returns (address) {
        return IDiamondLoupe(address(diamond)).facetAddress(sel);
    }

    function _unmount(bytes4 sel) internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = sel;
        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, one);
        IDiamondCut(address(diamond)).diamondCut(remove, address(0), "");
    }

    function _mountOne(bytes4 sel, address facet) internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = sel;
        IDiamondCut.FacetCut[] memory add = new IDiamondCut.FacetCut[](1);
        add[0] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Add, one);
        IDiamondCut(address(diamond)).diamondCut(add, address(0), "");
    }

    /// Puts the rig into the shape the live diamond is in: a seated arbiter, a
    /// chief, a funded vault and a floor. The cut is then applied on top of a
    /// live arbitration namespace rather than an empty one, which is the only
    /// way the storage-continuity claim means anything — this work APPENDED a
    /// field to `ArbiterRegistryStorage.Data` and two fields to structs inside
    /// it.
    function _seedArbitration() internal {
        ArbiterRegistryFacet(address(diamond)).addArbiter(ARBITER);
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        ArbiterVaultFacet(address(diamond)).setArbiterFloor(7_000_000);

        usdc.mint(address(this), 11_000_000);
        usdc.approve(address(diamond), 11_000_000);
        ArbiterVaultFacet(address(diamond)).fundVault(11_000_000);
    }

    /// The diamond as Base Sepolia stands TODAY — before this cut.
    ///
    /// Built the honest way round: a full DeployFull-shaped diamond (which,
    /// since this work, already mounts the two new selectors) and then the
    /// difference against the CENSUS is removed. Which selectors to remove is
    /// therefore decided by what the chain answered, not by this cut's own
    /// `registryAddSelectors()` — a rig built from the script's own list would
    /// agree with the script no matter which group anything was filed under,
    /// and that is the fourth way to be fooled by a measurement.
    ///
    /// The count is checked afterwards against the census header too, so a rig
    /// that has quietly drifted from the live diamond stops being a stand-in
    /// without anybody noticing.
    ///
    /// ⚠️ WHAT THIS RIG IS NOT. Its facets carry TODAY'S code, so its behaviour
    /// is already post-cut even while its SHAPE is pre-cut. Every claim made
    /// against it here is a claim about routing. The one behavioural pre-cut
    /// claim the script makes — "both thresholds still read 100 000" — is
    /// therefore tested by its refusal, not by its success.
    function _deployPreCutDiamond() internal returns (DiamondProxy d) {
        d = _deployFullShapedDiamond();
        // The census this rig is measured against predates the unmount; see the
        // helper's own note for why the script cannot supply this any more.
        _mountHistoricalDealMetadata(d);

        bytes4[] memory onChain = _censusAt(".selectors", ".count");
        _conformToCensus(d, onChain);
    }

    /// Registry and factory, seeded so `fundVault` has a token to move.
    function _initDiamond() internal {
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), FEE_RECIPIENT, address(0xDEAD), address(diamond), address(agDeployer)
        );
    }

    /// A diamond built out of DeployFull's own selector lists — the same lists
    /// run() builds the live one from. A private hand-written set would drift
    /// from the live layout in silence, and then the shape claim would be about
    /// a diamond that does not exist.
    /// Every selector this checkout mounts that the census does not hold,
    /// filled in by _conformToCensus. COMPUTED, never declared: this is the
    /// surplus that used to be a hand-kept total.
    bytes4[] internal rigSurplusOverCensus;

    /// Cut the rig down to the census, and then prove it IS the census.
    ///
    /// ⚠️ THE SIZE OF THE DIFFERENCE IS COMPUTED, NEVER DECLARED. Whatever this
    /// checkout mounts that the census does not hold comes off, however many
    /// that is. The shape this helper replaced sized its array from a hand-kept
    /// total and refused when the count disagreed, so every cut landing in the
    /// tree reddened it and every red was answered by raising the total.
    ///
    /// The claim that takes the count's place is stronger, not weaker: after the
    /// removal the rig's selector set must EQUAL the census's, both directions
    /// checked. A count agrees with a swap; equality does not.
    ///
    /// The other direction deserves its own sentence. A selector the census
    /// holds and this checkout can no longer build is the case that arrives when
    /// a facet leaves the tree -- it reds HERE, naming the selector, instead of
    /// leaving the rig one door short of the diamond it claims to be.
    function _conformToCensus(DiamondProxy d, bytes4[] memory census) internal {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(d)).facets();

        uint256 routed;
        for (uint256 i = 0; i < all.length; i++) routed += all[i].functionSelectors.length;

        bytes4[] memory scratch = new bytes4[](routed);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = 0; j < all[i].functionSelectors.length; j++) {
                bytes4 sel = all[i].functionSelectors[j];
                if (!_contains(census, sel)) scratch[n++] = sel;
            }
        }

        // Kept for the locks that ask what the surplus IS, now that nothing
        // declares what it should be. Recorded before it is removed, because
        // after the removal it is gone from the diamond.
        delete rigSurplusOverCensus;
        for (uint256 i = 0; i < n; i++) rigSurplusOverCensus.push(scratch[i]);

        if (n > 0) {
            bytes4[] memory extra = new bytes4[](n);
            for (uint256 i = 0; i < n; i++) extra[i] = scratch[i];
            IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
            remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, extra);
            IDiamondCut(address(d)).diamondCut(remove, address(0), "");
        }

        for (uint256 i = 0; i < census.length; i++) {
            require(
                IDiamondLoupe(address(d)).facetAddress(census[i]) != address(0),
                string.concat(
                    "the rig is MISSING a selector the chain routed at this census: ",
                    vm.toString(census[i]),
                    " - this checkout no longer builds it, and a stand rehearsing a past cut has to mount it itself"
                )
            );
        }

        IDiamondLoupe.Facet[] memory conformed = IDiamondLoupe(address(d)).facets();
        uint256 routedAfter;
        for (uint256 i = 0; i < conformed.length; i++) routedAfter += conformed[i].functionSelectors.length;
        require(routedAfter == census.length, "the conformed rig routes a different number of selectors than the census holds");
        // ⚠️ THE ARBITER FACET IS TWO CONTRACTS IN THIS CHECKOUT AND ONE ON THE
        // CHAIN (16 September 2026). The split moved twenty-eight selectors to
        // ArbiterVaultFacet without touching a signature, so the SET above is
        // right either way — but the rig would carry one facet more than the
        // chain, and the signed cut rehearsed here would then meet a Replace
        // group spread over two addresses, which its pre-flight refuses and
        // should go on refusing. So the rig is put back into the chain's shape
        // instead of the check being loosened: one host for all fifty-nine.
        //
        // ⚠️ THIS CALL STAYS, and the line that stood here saying it would come
        // out the day the split landed was wrong. The rig is conformed to THIS
        // STAND'S census, read before the split, when one host routed all
        // fifty-nine arbiter selectors; the split landing on Base Sepolia
        // (17 September 2026, block 46 946 562) does not change that past.
        // Measured 18 September 2026 on EmergencyBrakeUpgrade: without this
        // call setUp reverts "the conformed rig has a different number of
        // facets than the live chain had" and the suite does not run.
        _mountArbiterAsOneHost(address(d));

        IDiamondLoupe.Facet[] memory conformedNow = IDiamondLoupe(address(d)).facets();
        require(
            conformedNow.length == CHAIN_FACETS,
            "the conformed rig has a different number of facets than the live chain had"
        );
    }

    /// ⚠️ A FACET THE DEPLOY SCRIPT NO LONGER CARRIES, MOUNTED HERE ON PURPOSE.
    ///
    /// This rig has to look like the chain did at THIS STAND'S CENSUS, and at
    /// that census DealMetadataFacet was mounted and answering 0xb6a03ff7. On
    /// 14 September 2026 the owner signed the cut that unmounted it, and
    /// script/DeployFull.s.sol stopped mounting it the same day.
    ///
    /// So the rig can no longer get it by borrowing the script's list, and that
    /// is the lesson rather than an inconvenience: a stand that rehearses a PAST
    /// cut must own the past itself. Borrowing the shape of the chain from a
    /// script that tracks the PRESENT is what let this whole class of drift go
    /// unnoticed for ten days.
    function _mountHistoricalDealMetadata(DiamondProxy target) internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = DealMetadataFacet.getDealTokenURI.selector;
        // ⚠️ ASKED OF THE CENSUS, NOT DECIDED HERE. Mount it only if the chain
        // routed it at this census and this checkout no longer builds it. A
        // standing "always mount" would be one more hand-kept fact about which
        // cuts have landed -- the exact species this file just stopped keeping
        // -- and it would revert as a duplicate Add the day DeployFull carries
        // the facet again.
        if (!_contains(_censusAt(".selectors", ".count"), sels[0])) return;
        if (IDiamondLoupe(address(target)).facetAddress(sels[0]) != address(0)) return;
        IDiamondCut.FacetCut[] memory c = new IDiamondCut.FacetCut[](1);
        c[0] = IDiamondCut.FacetCut(
            address(new DealMetadataFacet()), IDiamondCut.FacetCutAction.Add, sels
        );
        IDiamondCut(address(target)).diamondCut(c, address(0), "");
    }

    function _deployFullShapedDiamond() internal returns (DiamondProxy d) {
        IDiamondCut.FacetCut[] memory initCuts = deploy.buildInitCuts(
            address(new DiamondCutFacet()),
            address(new DiamondLoupeFacet()),
            address(new OwnershipFacet()),
            address(new RegistryFacet()),
            address(new FactoryFacet())
        );
        d = new DiamondProxy(address(this), initCuts, address(0), "");

        IDiamondCut(address(d)).diamondCut(
            deploy.buildRemainingCuts(
                address(new JobBoardFacet()),
                address(new ServiceBoardFacet()),
                address(new ArbiterRegistryFacet()),
                address(new ArbiterVaultFacet()),
                address(new ArbiterAccountabilityFacet()),
                address(new ArbiterApplicationsFacet()),
                address(new TreasuryLinkFacet()),
                address(new JobReceiptFacet()),
                address(new ReputationFacet())
            ),
            address(0),
            ""
        );
    }

    function _censusAt(string memory listKey, string memory countKey)
        internal view returns (bytes4[] memory out)
    {
        string memory json = vm.readFile(CENSUS_PATH);
        string[] memory raw = vm.parseJsonStringArray(json, listKey);
        require(
            raw.length == vm.parseJsonUint(json, countKey),
            "the census header promises a different number of selectors than it holds"
        );
        out = new bytes4[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            bytes memory b = vm.parseBytes(raw[i]);
            require(b.length == 4, "the census holds a string that is not a selector");
            out[i] = bytes4(b);
        }
    }

    function _assertSameSet(bytes4[] memory mine, bytes4[] memory theirs, string memory label) internal pure {
        assertEq(mine.length, theirs.length, string.concat(label, ": the two sides disagree on how many selectors there are"));
        for (uint256 i = 0; i < mine.length; i++) {
            bool found;
            for (uint256 j = 0; j < theirs.length; j++) {
                if (mine[i] == theirs[j]) { found = true; break; }
            }
            assertTrue(found, string.concat(label, ": this cut carries a selector the other side does not have"));
        }
        for (uint256 i = 0; i < theirs.length; i++) {
            bool found;
            for (uint256 j = 0; j < mine.length; j++) {
                if (theirs[i] == mine[j]) { found = true; break; }
            }
            assertTrue(found, string.concat(label, ": the other side has a selector this cut does not carry"));
        }
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }
}
