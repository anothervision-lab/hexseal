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
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";
import {MockUSDCB} from "./BoardsFixture.sol";
import {UpgradeAppealDepositSoftRefund} from "../script/UpgradeAppealDepositSoftRefund.s.sol";

/// A facet standing in for "some other code entirely behind the same selector".
/// Used to prove the codehash probe is reading the CODE and not merely noticing
/// that an address changed.
contract ImpostorArbiterFacet {
    function resolveAppeal(address) external pure { revert("impostor"); }
}

contract AppealDepositSoftRefundUpgradeTest is Test {
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

    /// ⚠️ WHAT THE TREE CARRIES THAT THE CHAIN DOES NOT, AND WHY IT IS NOT THIS
    /// CUT'S BUSINESS — written by hand, BY SIGNATURE TEXT, never taken from any
    /// script's lists.
    ///
    /// `notifyWorkHandedIn()` is on RegistryFacet and ships with
    /// script/UpgradeRegistryHandInSignal.s.sol, a different cut on a different
    /// facet. DeployFull already mounts it, so a rig built from today's tree has
    /// it and the live chain does not. This cut touches neither that facet nor
    /// that selector, which is why the two are order-independent.
    uint256 constant GROWN_ELSEWHERE    = 1;
    uint256 constant EXTRA_BEYOND_CHAIN = GROWN_ELSEWHERE;

    function _grownElsewhere() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](GROWN_ELSEWHERE);
        sels[0] = bytes4(keccak256("notifyWorkHandedIn()"));
    }

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
        upgrade.assertReplaceListCoversTheWholeFacet(upgrade.replaceSelectors());
        assertEq(
            upgrade.artifactSelectors().length,
            ARBITER_SELECTORS,
            "the compiled ArbiterRegistryFacet exposes a different number of functions than this cut mounts"
        );
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
        bytes4[] memory compiled = upgrade.artifactSelectors();
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
    /// belong to somebody else. Two conditions, so the exemption can neither go
    /// stale nor quietly cover a hole in this cut.
    function test_TheGrowthBeyondThisCutIsRealAndBelongsToAnotherFacet() public view {
        bytes4[] memory grown = _grownElsewhere();
        bytes4[] memory registryAbi = _abiOf("out/RegistryFacet.sol/RegistryFacet.json");
        bytes4[] memory arbiterAbi  = upgrade.artifactSelectors();
        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(
                _contains(registryAbi, grown[i]),
                "an exemption names a selector RegistryFacet does not implement - the exemption is stale"
            );
            assertFalse(
                _contains(arbiterAbi, grown[i]),
                "an exemption names a selector that IS on ArbiterRegistryFacet - it would hide a hole in this very cut"
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
        upgrade.assertTheCompiledFacetNeedsNoAddGroup(address(diamond));

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

        upgrade.assertStorageContinuity(before_, upgrade.snapshotArbiterStorage(address(diamond)));
        assertEq(before_.arbiterCount, 1, "precondition: the seat this test added is not there");
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getArbiters().length,
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
        _unmount(ArbiterRegistryFacet.getAppealVotes.selector);
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
        _unmount(ArbiterRegistryFacet.getAppealVotes.selector);
        vm.expectRevert(
            abi.encodeWithSignature(
                "Error(string)",
                "pre-flight: the compiled facet exposes a function that is mounted nowhere - this cut needs an Add group and has none"
            )
        );
        upgrade.assertTheCompiledFacetNeedsNoAddGroup(address(diamond));
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
        _unmount(ArbiterRegistryFacet.getAppealVotes.selector);
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
            upgrade.replaceSelectors(),
            deploy.arbiterRegistryFacetSelectors(),
            "this cut vs DeployFull"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Rig and helpers
    // ════════════════════════════════════════════════════════════════════

    function _deployPreCutDiamond() internal returns (DiamondProxy d) {
        d = _deployFullShapedDiamond();

        bytes4[] memory onChain = _censusAt(".selectors", ".count");
        IDiamondLoupe.Facet[] memory all = IDiamondLoupe(address(d)).facets();

        bytes4[] memory extra = new bytes4[](EXTRA_BEYOND_CHAIN);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = 0; j < all[i].functionSelectors.length; j++) {
                bytes4 sel = all[i].functionSelectors[j];
                if (!_contains(onChain, sel)) {
                    require(n < EXTRA_BEYOND_CHAIN, "the local rig has more selectors than the chain by more than the cut queued behind this one");
                    extra[n++] = sel;
                }
            }
        }
        require(n == EXTRA_BEYOND_CHAIN, "the local rig does not differ from the chain by exactly the cut queued behind this one");
        // And it must be the selector the exemption NAMES, not merely one of
        // the right size.
        require(extra[0] == _grownElsewhere()[0], "the rig differs from the chain by a selector the exemption does not name");

        IDiamondCut.FacetCut[] memory remove = new IDiamondCut.FacetCut[](1);
        remove[0] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, extra);
        IDiamondCut(address(d)).diamondCut(remove, address(0), "");

        uint256 routed;
        IDiamondLoupe.Facet[] memory after_ = IDiamondLoupe(address(d)).facets();
        for (uint256 i = 0; i < after_.length; i++) routed += after_[i].functionSelectors.length;
        require(routed == CHAIN_ROUTED, "the local pre-cut rig routes a different number of selectors than the live chain");
        require(after_.length == CHAIN_FACETS, "the local pre-cut rig has a different number of facets than the live chain");
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
                address(new ArbiterAccountabilityFacet()),
                address(new ArbiterApplicationsFacet()),
                address(new DealMetadataFacet()),
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
}
