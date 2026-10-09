// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The stand for script/UpgradeAppealDepositSoftRefund.s.sol — the diamondCut
// that replaces ArbiterRegistryFacet so a won appeal whose deposit the token
// refuses no longer locks the whole escrow.
//
// ⚠️ WHY A STAND AT ALL, WHEN THE SCRIPT HAS A DRY RUN. A dry run proves the
// script survives TODAY'S chain. It cannot prove the script survives the chain
// it will meet at the moment somebody signs, and it cannot run in CI at all —
// it needs a network. Everything below runs offline, and the questions that
// decide whether the cut lands or reverts are answered from sources this file
// does not own:
//
//   * "does the list cover the facet" — the expected side is solc's own
//     `methodIdentifiers`, read out of the build artifact, not the list in the
//     script;
//   * "is every selector mounted, and is anything else on that facet" — the
//     expected side is a census read off Base Sepolia and committed as data
//     (test/fixtures/chain-2026-08-31-appeal-soft-refund-selectors.json).
//
// Neither is derived from the thing being checked. A stand that asked
// `upgrade.replaceSelectors()` what is mounted on chain would agree with the
// script no matter which group anything was filed under — that is the fourth
// way to be fooled by a measurement, and it cost a whole cut on 16 August 2026.
//
// ⚠️ THE SHAPE OF THIS ONE IS THE QUIET KIND, AND MORE SO THAN MOST. It is a
// pure Replace: fifty-nine selectors in, fifty-nine out, routed count unmoved,
// facet count unmoved, and — unlike the Factory cut — there is no access check
// that changes its answer across it. EVERY shape check in this file would pass
// just as happily on a cut that was signed against the wrong commit and shipped
// the code that is already running.
//
// So the claim that the cut DID something rests on one thing only, and it is
// exercised in both directions below: the CODE behind the selectors.
//
//     before   extcodehash(mounted) != keccak256(artifact deployedBytecode)
//     after    extcodehash(mounted) == keccak256(artifact deployedBytecode)
//
// The expected side is solc's compiled output; the actual side is the chain's
// own `extcodehash`. Neither is this file and neither is the script.
//
// ⚠️ WHAT THIS STAND CANNOT ANSWER, SAID OUT LOUD. Whether the soft refund
// BEHAVES correctly is not asked here — that is measured in test/Diamond.t.sol
// by the five locks that came with commit 8c9114ee
// (test_AWonAppealOpensTheEscrowEvenIfTheDepositCannotBeDelivered and its four
// neighbours). This file asks only the upgrade questions: does the cut land,
// does it move nothing it should not, and is the code that ends up mounted the
// code this checkout compiles.

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
import {UpgradeAppealDepositSoftRefund} from "../script/UpgradeAppealDepositSoftRefund.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {ArbiterSplitRig} from "./ArbiterSplitRig.sol";

/// A facet standing in for "some other code entirely behind the same selector".
/// Used to prove the codehash probe is reading the CODE and not merely noticing
/// that an address changed.
contract ImpostorArbiterFacet {
    function resolveAppeal(address) external pure { revert("impostor"); }
}

contract AppealDepositSoftRefundUpgradeTest is Test, ArbiterSplitRig {
    UpgradeAppealDepositSoftRefund upgrade;
    DeployFull deploy;
    DiamondProxy diamond;
    MockUSDCB usdc;

    address constant FEE_RECIPIENT = address(0xFEE);

    /// The census, and the things it is held to before it is believed.
    string constant CENSUS_PATH = "test/fixtures/chain-2026-08-31-appeal-soft-refund-selectors.json";
    address constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;

    /// Read off Base Sepolia on 31 August 2026 at block 46201329 and written
    /// down BY HAND here, so that a facet which silently grows or loses a
    /// function stops at this line instead of at the signature.
    uint256 constant CHAIN_FACETS      = 13;

    uint256 constant CHAIN_ROUTED      = 221;
    uint256 constant ARBITER_SELECTORS = 59;

    /// EIP-170, re-declared here rather than imported from the script. The
    /// chain's rule, not this project's — and reading the constant out of the
    /// thing being measured is exactly the mistake this file exists to avoid.
    uint256 constant CONTRACT_SIZE_LIMIT = 24_576;

    function setUp() public {
        upgrade = new UpgradeAppealDepositSoftRefund();
        deploy  = new DeployFull();
        usdc    = new MockUSDCB();
        diamond = _deployPreCutDiamond();
        _initDiamond();
    }

    // ════════════════════════════════════════════════════════════════════
    // The census is the one taken for THIS script, and for THIS diamond
    // ════════════════════════════════════════════════════════════════════

    /// The trap here is not "the census is stale" — it is "an old census was
    /// reused for a NEW script". Compared against the script's own
    /// `scriptPath()` rather than against a literal in this file, because a
    /// literal here would travel with a copy-paste of the file.
    function test_CensusIsTheOneTakenForThisScript() public view {
        string memory json = vm.readFile(CENSUS_PATH);
        assertEq(
            keccak256(bytes(vm.parseJsonString(json, ".forScript"))),
            keccak256(bytes(upgrade.scriptPath())),
            "this census was taken for a DIFFERENT cut - it does not describe what is being checked"
        );
        assertEq(
            vm.parseJsonAddress(json, ".diamond"),
            CENSUS_DIAMOND,
            "this census was taken from a different diamond"
        );
        assertEq(vm.parseJsonUint(json, ".count"), CHAIN_ROUTED, "census count disagrees with the hand-written literal");
        assertEq(vm.parseJsonUint(json, ".facetCount"), CHAIN_FACETS, "census facet count disagrees with the hand-written literal");
        assertEq(
            vm.parseJsonUint(json, ".arbiterRegistryCount"),
            ARBITER_SELECTORS,
            "census arbiter count disagrees with the hand-written literal"
        );
    }

    /// The census's own two lists must agree with each other: the fifty-nine on
    /// the arbiter facet are a subset of the 221 routed. A census that failed
    /// this would be describing two different moments.
    function test_TheCensusIsInternallyConsistent() public view {
        bytes4[] memory routed = _censusAt(".selectors", ".count");
        bytes4[] memory arb    = _censusAt(".arbiterRegistrySelectors", ".arbiterRegistryCount");
        for (uint256 i = 0; i < arb.length; i++) {
            assertTrue(_contains(routed, arb[i]), "the census puts a selector on the arbiter facet that it does not route at all");
        }
        for (uint256 i = 0; i < routed.length; i++) {
            for (uint256 j = i + 1; j < routed.length; j++) {
                assertTrue(routed[i] != routed[j], "the census lists the same selector twice - a diamond cannot route one selector to two facets");
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // The two grouping questions the chain punishes
    // ════════════════════════════════════════════════════════════════════

    /// Oracle: solc. The hand-written list against `methodIdentifiers`, both
    /// directions, so a swap cannot pass on a matching count.
    function test_TheReplaceListCoversExactlyTheCompiledFacet() public view {
        // The compiled side with the growth queued behind this cut taken out BY
        // NAME — the script ran and its list may not be edited, while the pair
        // it is compared with keeps growing. See `_grownAfterThisCut`.
        upgrade.assertReplaceListCovers(upgrade.replaceSelectors(), _compiledAsThisCutSawIt());
        assertEq(
            upgrade.artifactSelectors().length + _shrunkAfterThisCut().length,
            ARBITER_SELECTORS + _grownAfterThisCut().length,
            "the compiled ArbiterRegistryFacet exposes a different number of functions than this cut mounts plus what is queued behind it, less what has left it"
        );
    }

    /// ⚠️ WHAT THE PAIR **LOST** AFTER THIS CUT WAS SIGNED (9 October 2026), by
    /// SIGNATURE TEXT for the same reason the growth list uses it: the three doors
    /// of the governance hand over a verdict are not in this checkout, so there is
    /// no `.selector` to take, and a hand-typed signature keeps the four bytes
    /// checkable by a reader. Verified offline with `cast sig`:
    /// 0x42a71c6c / 0x5533316c / 0x69315118.
    ///
    /// Named rather than counted: a FOURTH door leaving still reds here.
    function _shrunkAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](3);
        sels[0] = bytes4(keccak256("overturnVerdict(address,bool)"));
        sels[1] = bytes4(keccak256("freezeVerdict(address)"));
        sels[2] = bytes4(keccak256("unfreezeVerdict(address)"));
    }

    /// ⚠️ WHAT THE PAIR GREW **AFTER** THIS CUT WAS SIGNED — by SIGNATURE TEXT,
    /// never taken from the script's lists or from the artifact.
    ///
    ///   • withdrawAppealShare(address), getAppealShareOwed(address,address),
    ///     getAppealLedger(address), quoteAppealDeposit(address) —
    ///     17 September 2026, the appeal economics, plus settleAppealDebts(uint256)
    ///     and getAppealDebts() the same day — all six on ArbiterVaultFacet.
    ///
    /// Held to "real, and not in this cut's Replace group" by
    /// test_TheGrowthBeyondThisCutIsRealAndBelongsToAnotherFacet.
    function _grownAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](11);
        sels[0] = bytes4(keccak256("withdrawAppealShare(address)"));
        sels[1] = bytes4(keccak256("getAppealShareOwed(address,address)"));
        sels[2] = bytes4(keccak256("getAppealLedger(address)"));
        sels[3] = bytes4(keccak256("quoteAppealDeposit(address)"));
        sels[4] = bytes4(keccak256("settleAppealDebts(uint256)"));
        sels[5] = bytes4(keccak256("getAppealDebts()"));
        // And the two of 18 September 2026 on the arbiter registry: item D1's
        // public door for a dead dispute claim, and the read a screen needs now
        // that the appeal quorum moves with the corps.
        sels[6] = bytes4(keccak256("abandonClaim(address)"));
        sels[7] = bytes4(keccak256("getAppealPanel(address)"));
        // And the three of 22 September 2026, when the seat stopped being
        // hostage money and the bond moved to the CASE: the arbiter's door to
        // collect the bond of a case that ended without his verdict, and the
        // two reads a screen needs beside that button. All three on
        // ArbiterVaultFacet.
        sels[8] = bytes4(keccak256("withdrawCaseBond(address)"));
        sels[9] = bytes4(keccak256("getCaseBond(address)"));
        sels[10] = bytes4(keccak256("getJudgingCount(address)"));
    }

    /// The compiled pair minus the named growth. Every name must actually be in
    /// the artifact, or the subtraction would be silently subtracting nothing.
    function _compiledAsThisCutSawIt() internal view returns (bytes4[] memory out) {
        bytes4[] memory compiled = upgrade.artifactSelectors();
        bytes4[] memory grown = _grownAfterThisCut();
        for (uint256 i = 0; i < grown.length; i++) {
            require(_contains(compiled, grown[i]), "the growth allowance names a function the compiled pair does not have");
        }
        out = new bytes4[](compiled.length - grown.length);
        uint256 k;
        for (uint256 i = 0; i < compiled.length; i++) {
            if (!_contains(grown, compiled[i])) out[k++] = compiled[i];
        }
    }

    /// ⚠️ THE LOAD-BEARING ONE. Oracle: the committed census, i.e. the live
    /// chain. The script supplies only the actual side — which group each
    /// selector was filed under. Every selector this cut files under Replace
    /// must be routed on the live chain, or `Replace` reverts "Diamond:
    /// selector not found" and takes the whole cut with it after the facet has
    /// been paid for.
    function test_TheChainSaysEverySelectorIsMountedAndSoBelongsInReplace() public view {
        bytes4[] memory onChain = _censusAt(".selectors", ".count");
        bytes4[] memory sels    = upgrade.replaceSelectors();
        assertEq(sels.length, ARBITER_SELECTORS, "the Replace group is not fifty-nine long");
        for (uint256 i = 0; i < sels.length; i++) {
            assertTrue(
                _contains(onChain, sels[i]),
                "a selector filed under Replace is NOT routed on the live chain - Replace would revert and take the cut"
            );
        }
    }

    /// The stronger form: set equality against the census's per-facet list, in
    /// BOTH directions. Catches the selector this cut carries that the facet no
    /// longer holds (Replace reverts) and the one the facet holds that this cut
    /// leaves behind (a live selector left pointing at code that no longer
    /// implements it).
    function test_TheReplaceGroupIsExactlyWhatTheArbiterFacetHoldsOnChain() public view {
        _assertSameSet(
            upgrade.replaceSelectors(),
            _censusAt(".arbiterRegistrySelectors", ".arbiterRegistryCount"),
            "Replace vs the live arbiter facet"
        );
    }

    /// ⚠️ "NO Add GROUP" IS A CLAIM, AND THIS IS WHERE IT IS EARNED. Asked of
    /// the census over the WHOLE diamond, not of the script's list: does the
    /// compiled facet expose anything routed nowhere? One such function would
    /// need an `Add` element, and this cut has none.
    function test_TheCompiledFacetGainsNothingAndSoNeedsNoAddGroup() public view {
        bytes4[] memory onChain  = _censusAt(".selectors", ".count");
        bytes4[] memory compiled = _compiledAsThisCutSawIt();
        for (uint256 i = 0; i < compiled.length; i++) {
            assertTrue(
                _contains(onChain, compiled[i]),
                "the compiled facet exposes a function mounted nowhere on the live chain - this cut needs an Add group and has none"
            );
        }
    }

    /// ⚠️ THE LOCK FOR THE MUTATION "FILE ONE OF THEM UNDER Add INSTEAD". The
    /// cut must be ONE element and that element must be Replace. A count of
    /// selectors alone would not see it: moving a selector from the Replace
    /// group into a new Add group keeps the union of fifty-nine identical.
    function test_TheCutIsOneReplaceAndNothingElse() public view {
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(0xFACE7));
        assertEq(cuts.length, 1, "this cut must be a single element - an Add or a Remove has appeared");
        assertTrue(
            cuts[0].action == IDiamondCut.FacetCutAction.Replace,
            "the single element of this cut is not a Replace - Add reverts on a mounted selector and would drop the whole transaction"
        );
        assertEq(cuts[0].facetAddress, address(0xFACE7), "the cut does not point at the facet it was handed");
        assertEq(cuts[0].functionSelectors.length, ARBITER_SELECTORS, "the cut does not carry all fifty-nine selectors");
        _assertSameSet(cuts[0].functionSelectors, upgrade.replaceSelectors(), "buildCuts vs replaceSelectors");
    }

    /// The growth this rig carries beyond the chain must be REAL and must
    /// belong to somebody else. Two conditions, so a surplus can neither be
    /// imaginary nor quietly cover a hole in this cut.
    ///
    /// ⚠️ THE SURPLUS IS MEASURED, NOT DECLARED. It used to be a hand-written
    /// list sized by two hand-written constants, and a list like that answers
    /// "is the surplus what I said it was", which is a question about the list.
    /// Now it is whatever the rig actually carried beyond the census, and the
    /// two conditions below are asked of THAT. Land a cut, queue another, drop
    /// one: nothing here needs touching, and nothing here can be bought by
    /// touching it.
    function test_TheGrowthBeyondThisCutIsRealAndBelongsToAnotherFacet() public view {
        bytes4[] memory grown = rigSurplusOverCensus;
        assertGt(grown.length, 0, "the rig carries no surplus over the census at all - this lock has nothing to be about");

        bytes4[] memory registryAbi = _abiOf("out/RegistryFacet.sol/RegistryFacet.json");
        bytes4[] memory factoryAbi  = _abiOf("out/FactoryFacet.sol/FactoryFacet.json");
        bytes4[] memory treasuryAbi = _abiOf("out/TreasuryLinkFacet.sol/TreasuryLinkFacet.json");
        bytes4[] memory appsAbi     = _abiOf("out/ArbiterApplicationsFacet.sol/ArbiterApplicationsFacet.json");
        // Added 18 September 2026: the job board is now one of the facets whose
        // growth reaches this rig. "An arbiter is not a player in the market"
        // put three reads on it (getOpenMarketItems, pruneClosedApplications,
        // getAppliedJobIds), and the registry one (getOpenDealCount, already
        // covered by registryAbi above). Without this line the surplus carried
        // a selector no NAMED facet implemented, which is what this lock exists
        // to refuse — and it was right to go red: the name was simply missing.
        bytes4[] memory jobBoardAbi = _abiOf("out/JobBoardFacet.sol/JobBoardFacet.json");
        // Added 20 September 2026, and for the same reason the line above it
        // was: the handover's second condition put getHandoverReadiness() on
        // the accountability facet — every term of the condition, its floor and
        // the verdict, out of the same function activateDAO() calls. The other
        // selector of that rule, getLiveDeals(), is already covered by
        // registryAbi above. Without this line the surplus carried a selector no
        // NAMED facet implemented, and the lock was right to go red: the name
        // was simply missing.
        bytes4[] memory accountabilityAbi = _abiOf("out/ArbiterAccountabilityFacet.sol/ArbiterAccountabilityFacet.json");
        // Added 20 September 2026, third time for the third time's reason: the
        // corps stopped asking for experience and now asks only for a run of
        // clean deals, so getStreakStanding() went onto the reputation facet —
        // the streak, the deals that bought none of it, and the rule behind
        // both, in one read. Without this line the surplus carried a selector no
        // NAMED facet implemented, and the lock was right to go red.
        bytes4[] memory reputationAbi = _abiOf("out/ReputationFacet.sol/ReputationFacet.json");
        bytes4[] memory arbiterAbi  = upgrade.artifactSelectors();
        bytes4[] memory queued      = _grownAfterThisCut();

        for (uint256 i = 0; i < grown.length; i++) {
            // The growth queued on THIS pair behind this cut, named by
            // signature: real (it is in the pair's ABI) and not a hole in this
            // cut (it is not in the Replace group). Asked here rather than
            // waved through, so the allowance cannot cover a selector the cut
            // did mount.
            if (_contains(queued, grown[i])) {
                assertTrue(_contains(arbiterAbi, grown[i]), "the growth allowance is stale: no such function in the arbiter pair");
                assertFalse(
                    _contains(upgrade.replaceSelectors(), grown[i]),
                    "the growth allowance covers a selector this cut REPLACED - it would hide a hole in this very cut"
                );
                continue;
            }
            // Implemented by a NAMED facet of this checkout, never merely
            // "somewhere": a surplus nobody implements is a rig carrying a door
            // that leads nowhere.
            assertTrue(
                _contains(registryAbi, grown[i]) || _contains(factoryAbi, grown[i])
                    || _contains(treasuryAbi, grown[i]) || _contains(appsAbi, grown[i])
                    || _contains(jobBoardAbi, grown[i]) || _contains(accountabilityAbi, grown[i])
                    || _contains(reputationAbi, grown[i]),
                string.concat(
                    "the rig carries a selector no named facet of this checkout implements: ",
                    vm.toString(grown[i])
                )
            );
            assertFalse(
                _contains(arbiterAbi, grown[i]),
                string.concat(
                    "the rig's surplus includes a selector that IS on ArbiterRegistryFacet - it would hide a hole in this very cut: ",
                    vm.toString(grown[i])
                )
            );
        }
    }

    /// The rig really is shaped like the chain, so everything measured on it
    /// means something about the chain.
    function test_TheLocalRigHasTheSameShapeAsTheLiveChain() public view {
        assertEq(_routed(), CHAIN_ROUTED, "the rig routes a different number of selectors than the live chain");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length,
            CHAIN_FACETS,
            "the rig has a different number of facets than the live chain"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // The cut lands, and moves nothing it should not
    // ════════════════════════════════════════════════════════════════════

    function test_ThePreFlightPassesAndTheCutLands() public {
        bytes4[] memory sels = upgrade.replaceSelectors();

        address previousFacet = upgrade.assertAllMountedOnOneFacet(sels, address(diamond));
        upgrade.assertNothingIsLeftBehind(sels, previousFacet, address(diamond));
        // The compiled side handed in without the growth queued behind this cut.
        upgrade.assertNoAddGroupNeeded(address(diamond), _compiledAsThisCutSawIt());

        uint256 routedBefore = _routed();
        uint256 facetsBefore = IDiamondLoupe(address(diamond)).facetAddresses().length;

        ArbiterRegistryFacet fresh = new ArbiterRegistryFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(fresh)), address(0), "");

        upgrade.assertRouted(sels, address(fresh), address(diamond));
        assertEq(_routed(), routedBefore, "a pure Replace moved the routed-selector count");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length,
            facetsBefore,
            "a pure Replace moved the facet count"
        );
        assertEq(
            IDiamondLoupe(address(diamond)).facetFunctionSelectors(previousFacet).length,
            0,
            "the old facet still holds selectors - the Replace did not move all of them"
        );
        assertEq(
            IDiamondLoupe(address(diamond)).facetFunctionSelectors(address(fresh)).length,
            ARBITER_SELECTORS,
            "the new facet does not hold all fifty-nine"
        );
    }

    /// The arbiter namespace reads the same on both sides. This cut appends
    /// nothing, so this is guarding the CLAIM that nothing was appended — a
    /// facet compiled from a source whose layout had quietly moved would
    /// replace the old one without complaint and read the wrong words from the
    /// same slots.
    function test_TheArbiterStorageReadsTheSameOnBothSidesOfTheCut() public {
        vm.prank(address(this));
        ArbiterRegistryFacet(address(diamond)).addArbiter(address(0xA1));

        UpgradeAppealDepositSoftRefund.StorageSnapshot memory before_ =
            upgrade.snapshotArbiterStorage(address(diamond));

        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(address(new ArbiterRegistryFacet())), address(0), ""
        );

        // ⚠️ AND THEN THE SEPTEMBER SPLIT IS PLAYED OUT. The cut above is the
        // one that was SIGNED and it mounts all fifty-nine on one fresh
        // ArbiterRegistryFacet, which since the split implements thirty-one of
        // them. `getArbiters`, read on both sides of the cut here, is one of the
        // twenty-eight that moved. Playing the move out is what the chain will
        // do; rewriting the signed script is not.
        _replayArbiterVaultSplit(address(diamond));

        upgrade.assertStorageContinuity(before_, upgrade.snapshotArbiterStorage(address(diamond)));
        assertEq(before_.arbiterCount, 1, "precondition: the seat this test added is not there");
        assertEq(
            ArbiterVaultFacet(address(diamond)).getArbiters().length,
            1,
            "the seat did not survive the cut"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // The only thing that tells this cut apart from no cut at all
    // ════════════════════════════════════════════════════════════════════

    /// ⚠️ THE PROBE THIS WHOLE FILE LEANS ON, IN BOTH DIRECTIONS.
    ///
    /// Before the cut the rig runs a freshly compiled facet, so the probe must
    /// say "this IS the checkout" — which is exactly the state the script
    /// refuses to run against, and that refusal is asserted below. After a cut
    /// to a DIFFERENT contract's code it must say "this is NOT the checkout".
    /// Both directions, or a probe stuck on one answer would look identical to
    /// a working one.
    function test_TheCodehashProbeTellsThisCheckoutFromOtherCode() public {
        // ⚠️ THE PRE-CUT HOST HERE IS THE SPLIT DOUBLE, NOT A FACET
        // (16 September 2026). The rig puts all fifty-nine arbiter selectors on
        // one address, the way the chain has them, and that address is
        // PreSplitArbiterDispatcher rather than a plain ArbiterRegistryFacet.
        // The probe below reads the CODE behind `resolveAppeal`, so the scene
        // first puts a real, freshly compiled facet there — which is the state
        // the probe is being asked about, and the state the chain is in.
        _replaceOne(ArbiterRegistryFacet.resolveAppeal.selector, address(new ArbiterRegistryFacet()));

        assertEq(
            upgrade.liveFacetCodehash(address(diamond)),
            upgrade.thisCheckoutCodehash(),
            "the rig mounts a freshly compiled facet, so the probe should recognise it"
        );

        // Same selector, different code. The probe must notice the CODE, not
        // merely that an address changed.
        _replaceOne(ArbiterRegistryFacet.resolveAppeal.selector, address(new ImpostorArbiterFacet()));
        assertTrue(
            upgrade.liveFacetCodehash(address(diamond)) != upgrade.thisCheckoutCodehash(),
            "the probe did not notice that resolveAppeal now points at entirely different code"
        );
    }

    /// The pre-flight half refuses a diamond that already runs this code —
    /// otherwise a second run pays for an identical facet and cuts it in to
    /// change nothing, which reads afterwards exactly like a success.
    function test_ThePreFlightRefusesADiamondThatAlreadyRunsThisCode() public {
        // ⚠️ THE PRE-CUT HOST HERE IS THE SPLIT DOUBLE, NOT A FACET
        // (16 September 2026). The rig puts all fifty-nine arbiter selectors on
        // one address, the way the chain has them, and that address is
        // PreSplitArbiterDispatcher rather than a plain ArbiterRegistryFacet.
        // The probe below reads the CODE behind `resolveAppeal`, so the scene
        // first puts a real, freshly compiled facet there — which is the state
        // the probe is being asked about, and the state the chain is in.
        _replaceOne(ArbiterRegistryFacet.resolveAppeal.selector, address(new ArbiterRegistryFacet()));

        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: the mounted ArbiterRegistryFacet is ALREADY byte-for-byte this checkout - this cut has landed, or this is the wrong commit. Running would pay for a facet that changes nothing"
            )
        );
        upgrade.assertTheLiveFacetIsNotThisCheckout(address(diamond));
    }

    /// And the post-flight half must FAIL when the mounted code is not this
    /// checkout, or it is not measuring anything.
    function test_ThePostFlightRefusesCodeThatIsNotThisCheckout() public {
        _replaceOne(ArbiterRegistryFacet.resolveAppeal.selector, address(new ImpostorArbiterFacet()));
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "post-flight: the code behind resolveAppeal is NOT this checkout - the cut mounted something else, and the counts cannot see it"
            )
        );
        upgrade.assertTheLiveFacetIsThisCheckout(address(diamond));
    }

    /// The probe must refuse a diamond that does not route resolveAppeal at
    /// all, rather than reading the zero address as "some other code".
    function test_TheCodehashProbeRefusesADiamondWithoutTheSelector() public {
        _unmount(ArbiterRegistryFacet.resolveAppeal.selector);
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "resolveAppeal() is not mounted on this diamond at all - wrong address, or a diamond this cut was not written for"
            )
        );
        upgrade.liveFacetCodehash(address(diamond));
    }

    // ════════════════════════════════════════════════════════════════════
    // The pre-flight refusals
    // ════════════════════════════════════════════════════════════════════

    /// A selector filed under Replace that is not mounted is the exact shape
    /// that drops the whole cut on chain. The pre-flight must name it before a
    /// wei is spent.
    function test_ThePreFlightRefusesAReplaceSelectorThatIsNotMounted() public {
        _unmount(ArbiterVaultFacet.getAppealVotes.selector);
        // ⚠️ HOISTED ON PURPOSE. `upgrade.replaceSelectors()` is an external
        // call, and written inline as an argument it is evaluated BEFORE the
        // call under test -- it would swallow the expectRevert, and this test
        // would then pass against a script that refused nothing at all. Three
        // tests in this file were green that way on 31 August 2026 before the
        // arrangement was measured.
        bytes4[] memory sels = upgrade.replaceSelectors();
        address d = address(diamond);
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: a selector from Replace is not mounted - it belongs in Add, and Replace would revert"
            )
        );
        upgrade.assertAllMountedOnOneFacet(sels, d);
    }

    /// The same fact seen from the other side: the compiled facet exposing
    /// something routed nowhere means this cut needs an Add group it does not
    /// have.
    function test_ThePreFlightRefusesWhenTheCompiledFacetWouldNeedAnAddGroup() public {
        // ⚠️ THE GROWTH IS TAKEN OUT OF THE COMPILED SIDE HERE TOO. The four
        // appeal-economics selectors are unmounted on this rig by construction,
        // so the plain `assertTheCompiledFacetNeedsNoAddGroup` refuses with or
        // without the unmount below — a refusal this scene would then be
        // "proving" for free. With the growth taken out, the unmount is the
        // only thing left that can make it refuse.
        bytes4[] memory compiled = _compiledAsThisCutSawIt();
        _unmount(ArbiterVaultFacet.getAppealVotes.selector);
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: the compiled facet exposes a function that is mounted nowhere - this cut needs an Add group and has none"
            )
        );
        upgrade.assertNoAddGroupNeeded(address(diamond), compiled);
    }

    /// A Replace group spread over two facets breaks this cut's one assumption.
    function test_ThePreFlightRefusesAReplaceGroupSpreadOverTwoFacets() public {
        _replaceOne(ArbiterRegistryFacet.resolveAppeal.selector, address(new ImpostorArbiterFacet()));
        bytes4[] memory sels = upgrade.replaceSelectors();   // hoisted, see above
        address d = address(diamond);
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: the fifty-nine selectors are not all on one facet - this cut assumes one ArbiterRegistryFacet"
            )
        );
        upgrade.assertAllMountedOnOneFacet(sels, d);
    }

    /// A selector left behind on the facet being replaced would keep pointing
    /// at an address whose code no longer implements it.
    function test_ThePreFlightRefusesASelectorLeftBehindOnTheOldFacet() public {
        bytes4[] memory sels = upgrade.replaceSelectors();
        address host = upgrade.assertAllMountedOnOneFacet(sels, address(diamond));
        // Give the facet one more selector than this cut carries.
        _mountOne(bytes4(0xDEADBEEF), host);
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: the facet being replaced holds a different number of selectors than this cut carries"
            )
        );
        upgrade.assertNothingIsLeftBehind(sels, host, address(diamond));
    }

    /// A real diamond really does revert a Replace of an unmounted selector.
    /// The pre-flights above exist to catch this BEFORE it costs a facet, so
    /// the thing they are protecting against is worth demonstrating once.
    function test_ADiamondRejectsAReplaceOfAnUnmountedSelector() public {
        _unmount(ArbiterVaultFacet.getAppealVotes.selector);
        // Hoisted for the same reason: buildCuts is an external call.
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(address(new ArbiterRegistryFacet()));
        address d = address(diamond);
        vm.expectRevert(bytes("Diamond: selector not found"));
        IDiamondCut(d).diamondCut(cuts, address(0), "");
    }

    /// ⚠️ AND THE OTHER HALF OF THE PAIR THAT DROPS A CUT: a real diamond
    /// really does revert an `Add` of a selector that IS mounted. This is what
    /// would happen if any of the fifty-nine were filed under Add, and it is
    /// why `test_TheCutIsOneReplaceAndNothingElse` is not a formality.
    function test_ADiamondRejectsAnAddOfAMountedSelector() public {
        bytes4[] memory one = new bytes4[](1);
        one[0] = ArbiterRegistryFacet.resolveAppeal.selector;
        IDiamondCut.FacetCut[] memory add = new IDiamondCut.FacetCut[](1);
        add[0] = IDiamondCut.FacetCut(
            address(new ArbiterRegistryFacet()), IDiamondCut.FacetCutAction.Add, one
        );
        vm.expectRevert(bytes("Diamond: selector exists"));
        IDiamondCut(address(diamond)).diamondCut(add, address(0), "");
    }

    // ════════════════════════════════════════════════════════════════════
    // The ceiling
    // ════════════════════════════════════════════════════════════════════

    /// 209 bytes of headroom is thin enough that this is a live risk, not a
    /// formality. Held to the literal above, not to the script's constant.
    function test_TheFacetFitsUnderTheCeiling() public {
        upgrade.assertTheImplementationFitsOnChain();
        // Taken from a REAL deployment rather than from the script's own reading
        // of the artifact, so the two cannot agree by both being wrong.
        uint256 size = address(new ArbiterRegistryFacet()).code.length;
        assertLe(size, CONTRACT_SIZE_LIMIT, "the compiled facet is over EIP-170");
        assertEq(upgrade.compiledFacetSize(), size, "the script's idea of the facet size is not the size it deploys at");
        assertEq(
            upgrade.facetHeadroom(),
            CONTRACT_SIZE_LIMIT - size,
            "the headroom the script reports is not the headroom there is"
        );
        assertEq(upgrade.CONTRACT_SIZE_LIMIT(), CONTRACT_SIZE_LIMIT, "the script and this bench disagree about EIP-170");
    }

    /// The fix made the facet SMALLER, and the census records the size of the
    /// code running today. The two differing is what makes "there is something
    /// to ship" a measurement rather than a hope.
    function test_TheCompiledFacetIsNotTheSizeOfTheOneOnChain() public {
        uint256 live = vm.parseJsonUint(vm.readFile(CENSUS_PATH), ".arbiterRegistryCodeSize");
        assertTrue(
            live != upgrade.compiledFacetSize(),
            "the compiled facet is the same size as the one on chain - wrong commit, or nothing to ship"
        );
    }

    /// ⚠️ THE ASSUMPTION THE WHOLE CODEHASH PROBE RESTS ON, HELD TO A REAL
    /// DEPLOYMENT INSTEAD OF LEFT AS A SENTENCE IN A COMMENT.
    ///
    /// `thisCheckoutCodehash()` is the keccak of the ARTIFACT'S deployedBytecode.
    /// That is the same thing as the code of a deployed facet only while
    /// ArbiterRegistryFacet has no constructor arguments, no immutables and no
    /// link references. It has none today. Should it ever gain one, this test
    /// goes red and the probe stops quietly comparing two things that have
    /// stopped meaning the same thing.
    function test_TheFreshlyDeployedFacetHashesToTheArtifact() public {
        ArbiterRegistryFacet fresh = new ArbiterRegistryFacet();
        assertEq(
            address(fresh).codehash,
            upgrade.thisCheckoutCodehash(),
            "a freshly deployed facet does not hash to the artifact - the codehash probe is comparing two different things"
        );
    }

    /// The cut and a fresh DeployFull must mount the same set, or the next
    /// clean deploy and this diamond drift apart.
    function test_TheCutAndAFreshDeployMountTheSameSet() public view {
        _assertSameSet(
            // The growth queued behind this cut is added to THIS cut's side: a
            // fresh deploy mounts what the pair has today.
            _concat(upgrade.replaceSelectors(), _grownAfterThisCut()),
            // The pair: this cut mounted ONE facet, and that facet is two files
            // since the 16 September 2026 split. Same set of functions either
            // way — that is what makes it a split and not a change.
            // ⚠️ AND THE THREE THE PAIR LOST ON 9 OCTOBER 2026 GO ON DEPLOYFULL'S
            // SIDE, which is the mirror of the growth above. The governance hand over
            // a verdict — `overturnVerdict(address,bool)`, `freezeVerdict(address)`,
            // `unfreezeVerdict(address)` — left ArbiterRegistryFacet and left the
            // diamond the same day, so `DeployFull` no longer mounts them while this
            // cut's record still does. Named by their bytes in
            // ArbiterSplitRig.verdictHandDoors(), never counted: a fourth door
            // leaving still reds here.
            _concat(
                _concat(deploy.arbiterRegistryFacetSelectors(), deploy.arbiterVaultFacetSelectors()),
                verdictHandDoors()
            ),
            "this cut vs DeployFull"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Rig and helpers
    // ════════════════════════════════════════════════════════════════════

    function _deployPreCutDiamond() internal returns (DiamondProxy d) {
        d = _deployFullShapedDiamond();
        // The census this rig is measured against predates the unmount; see the
        // helper's own note for why the script cannot supply this any more.
        _mountHistoricalDealMetadata(d);

        bytes4[] memory onChain = _censusAt(".selectors", ".count");
        _conformToCensus(d, onChain);
    }

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

        // The three application doors this checkout stopped building on
        // 22 September 2026, put back where the census still has them. See
        // ArbiterSplitRig._mountRemovedApplicationDoors for why they go on the
        // applications facet that is already here rather than on a stub.
        _mountRemovedApplicationDoors(address(d), census);
        // And the three doors of the governance hand over a verdict, which left the
        // facet AND the chain on 9 October 2026. Same reason, same shape, one note:
        // see ArbiterSplitRig._mountRemovedVerdictHandDoors.
        _mountRemovedVerdictHandDoors(address(d), census);

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

    function _initDiamond() internal {
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), FEE_RECIPIENT, address(0xDEAD), address(diamond), address(agDeployer)
        );
    }

    function _routed() internal view returns (uint256 total) {
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(diamond)).facets();
        for (uint256 i = 0; i < all.length; i++) total += all[i].functionSelectors.length;
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

    function _replaceOne(bytes4 sel, address facet) internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = sel;
        IDiamondCut.FacetCut[] memory rep = new IDiamondCut.FacetCut[](1);
        rep[0] = IDiamondCut.FacetCut(facet, IDiamondCut.FacetCutAction.Replace, one);
        IDiamondCut(address(diamond)).diamondCut(rep, address(0), "");
    }

    function _contains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) if (haystack[i] == needle) return true;
        return false;
    }

    /// solc's own answer to "what does this facet expose", for a facet this cut
    /// does not touch. Read here rather than through the script, which has no
    /// business knowing about RegistryFacet at all.
    function _abiOf(string memory artifactPath) internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(artifactPath);
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i = 0; i < sigs.length; i++) out[i] = bytes4(keccak256(bytes(sigs[i])));
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

    /// Joins two selector lists. (This helper carried a docstring about "the
    /// pending arbiter-bond pair, not yet on the chain" from 8 September 2026.
    /// It described neither this function nor the world: those selectors
    /// reached the chain with the cuts of 17 and 19 September 2026, and
    /// `_pendingCut()` in test/DeployFullMatchesChain.t.sol is empty. Removed
    /// on 19 September 2026 rather than left to be believed.)
    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }
}
