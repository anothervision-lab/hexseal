// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// THE APPEAL SPLIT, PROVED ON A DIAMOND AND NOT ON PAPER (15 October 2026)
//
// The six doors of one appeal left ArbiterRegistryFacet for ArbiterAppealFacet
// because the registry stood 1 469 bytes under EIP-170. Every other stand in
// this repository builds the diamond ALREADY SPLIT, so none of them can tell
// "the split happened" from "the split was written down": a selector set that
// never moved looks identical either way.
//
// This file does the move. It mounts the thirty-three arbiter doors the way the
// chain mounts them — ONE address answering all of them — and then performs the
// diamondCut that carries the split, and asks the LOUPE what changed. Nothing
// here reads the source of a facet to decide what it implements.
//
// ── WHERE THE EXPECTED SIDE COMES FROM ───────────────────────────────────
// ⚠️ NOT from `DeployFull.arbiterAppealFacetSelectors()`. A stand that takes
// "which six moved" from the very list that mounts them agrees with itself and
// is green whatever happens — measured in this repository on 16 August 2026,
// when a deliberate corruption turned two stands red and left the one appointed
// to catch it green. The six are HAND-FIXED four-byte literals below, read off
// `out/ArbiterRegistryFacet.sol/ArbiterRegistryFacet.json` methodIdentifiers on
// 15 October 2026 BEFORE the split, which is the only moment at which they can
// be read without asking the thing under test:
//
//     6d35b861  raiseAppeal(address)
//     21100c8e  summonAppealPanel(address)
//     5f8093fa  getAppealSummons(address)
//     2b081afe  getAppealPanel(address)
//     bff14b7f  voteToOverturn(address)
//     0ae75609  resolveAppeal(address)
//
// They are the same four bytes AFTER the split, and that is the property the
// cut rests on: a selector is derived from the signature, not from the facet.
// ============================================================

import "forge-std/Test.sol";
import {DeployFull} from "../script/DeployFull.s.sol";
import {DiamondProxy, IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";
import {DiamondCutFacet, DiamondLoupeFacet, OwnershipFacet} from "../src/DiamondProxy.sol";
import {RegistryFacet} from "../src/RegistryFacet.sol";
import {FactoryFacet} from "../src/FactoryFacet.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAppealFacet} from "../src/facets/ArbiterAppealFacet.sol";
import {PreSplitArbiterDispatcher} from "./ArbiterSplitRig.sol";

contract AppealFacetSplitCutTest is Test {
    DeployFull internal deploy;
    DiamondProxy internal diamond;

    /// The pre-split host: one address answering all thirty-three arbiter
    /// doors, the way the chain answered them before this cut.
    address internal preSplitHost;

    /// Hand-fixed, taken before the split. See the header.
    function _theSix() internal pure returns (bytes4[] memory six) {
        six = new bytes4[](6);
        six[0] = bytes4(0x6d35b861); // raiseAppeal(address)
        six[1] = bytes4(0x21100c8e); // summonAppealPanel(address)
        six[2] = bytes4(0x5f8093fa); // getAppealSummons(address)
        six[3] = bytes4(0x2b081afe); // getAppealPanel(address)
        six[4] = bytes4(0xbff14b7f); // voteToOverturn(address)
        six[5] = bytes4(0x0ae75609); // resolveAppeal(address)
    }

    function _has(bytes4[] memory hay, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < hay.length; i++) if (hay[i] == needle) return true;
        return false;
    }

    function _concat(bytes4[] memory a, bytes4[] memory b) internal pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }

    function setUp() public {
        deploy = new DeployFull();

        IDiamondCut.FacetCut[] memory initCuts = deploy.buildInitCuts(
            address(new DiamondCutFacet()),
            address(new DiamondLoupeFacet()),
            address(new OwnershipFacet()),
            address(new RegistryFacet()),
            address(new FactoryFacet())
        );
        diamond = new DiamondProxy(address(this), initCuts, address(0), "");

        // ⚠️ THE PRE-SPLIT SHAPE IS A DOUBLE AND NOT A FROZEN COPY. The thirty
        // three selectors go on ONE address, and that address forwards each to
        // whichever of the two real, freshly compiled facets implements it — so
        // the code behind every door is TODAY's, and what this stand moves is
        // the ROUTING TABLE, which is the only thing a diamondCut can move.
        bytes4[] memory regSels = deploy.arbiterRegistryFacetSelectors();
        preSplitHost = address(
            new PreSplitArbiterDispatcher(
                address(new ArbiterRegistryFacet()),
                address(0),
                regSels,
                new bytes4[](0),
                address(new ArbiterAppealFacet()),
                _theSix()
            )
        );

        IDiamondCut.FacetCut[] memory mount = new IDiamondCut.FacetCut[](1);
        mount[0] = IDiamondCut.FacetCut(
            preSplitHost, IDiamondCut.FacetCutAction.Add, _concat(regSels, _theSix())
        );
        IDiamondCut(address(diamond)).diamondCut(mount, address(0), "");
    }

    /// The shape before the cut, asked of the loupe: one address holds the
    /// whole arbiter set, and each of the six answers from it.
    ///
    /// ⚠️ THE NUMBER FOLLOWS THE COMPILED TREE AND NOT THE DAY OF THE CUT, and
    /// saying which is the point. The host is built out of
    /// `DeployFull.arbiterRegistryFacetSelectors()` plus `_theSix()`, so what
    /// it holds is what the registry mounts TODAY. On 15 October 2026 that was
    /// twenty-seven and the sum was thirty-three; the entry bond added two to
    /// the registry on the morning of 8 November 2026 --
    /// `applyAsArbiterWithPermit(uint256,uint8,bytes32,bytes32)` and
    /// `revokeArbiterInvitation(address)`, filled by `DeployFull` as `sels[27]`
    /// and `sels[28]` -- taking the sum to thirty-five, and BOTH LEFT AGAIN
    /// THAT EVENING for ArbiterApplicationsFacet, taking it back to
    /// thirty-three.
    ///
    /// ⚠️ THE EVENING HAPPENED BECAUSE OF THIS FILE.
    /// `test_BothFacetsFitUnderEip170` below asks for more than 4 096 bytes of
    /// room on the registry, and its comment says the floor stands "high enough
    /// that losing the room this work bought would" red. The entry bond took
    /// the registry's margin 4 937 -> 3 716 and the floor broke; the two doors
    /// moved next door, where `acceptArbiterInvitationWithPermit` already
    /// lives, and the margin came back to 4 332. So this number went
    /// 33 -> 35 -> 33 inside one day, and the middle value is kept here rather
    /// than erased because it is the reason the move exists.
    ///
    /// Worked out by hand, and written out so no era has to be remembered:
    ///     the registry on the day of the cut          27
    ///   + the two doors of 8 November, morning         2
    ///   -------------------------------------------- 29
    ///   - the same two, that evening                  -2
    ///   -------------------------------------------- 27
    ///   + the six appeal doors `_theSix()` names       6
    ///   -------------------------------------------- 33
    ///
    /// ⚠️ A LITERAL AND NOT `regSels.length + 6`. The host's own list is the
    /// thing under measurement here; an expected side computed from it would
    /// agree with itself through any drift, which is the failure this file's
    /// header already records from 16 August 2026.
    function test_BeforeTheCutOneAddressHoldsAllThirtyThree() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        assertEq(
            loupe.facetFunctionSelectors(preSplitHost).length,
            33,
            "the pre-split host does not hold the whole arbiter set the registry compiles plus the six"
        );
        bytes4[] memory six = _theSix();
        for (uint256 i = 0; i < six.length; i++) {
            assertEq(
                loupe.facetAddress(six[i]),
                preSplitHost,
                "an appeal door does not answer from the pre-split host before the cut"
            );
        }
    }

    /// THE CUT. Two Replace groups, which is what the split is: no selector is
    /// added and none is retired, so neither `Add` nor `Remove` may appear.
    function _performTheSplitCut() internal returns (address registryAddr, address appealAddr) {
        registryAddr = address(new ArbiterRegistryFacet());
        appealAddr = address(new ArbiterAppealFacet());

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut(
            registryAddr, IDiamondCut.FacetCutAction.Replace, deploy.arbiterRegistryFacetSelectors()
        );
        cut[1] = IDiamondCut.FacetCut(appealAddr, IDiamondCut.FacetCutAction.Replace, _theSix());
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }

    /// @notice The measurement this file exists for: after the cut the six
    /// answer from the NEW address, and the registry routes none of them.
    function test_AfterTheCutTheSixAnswerFromTheNewAddressAndTheRegistryRoutesNone() public {
        (address registryAddr, address appealAddr) = _performTheSplitCut();
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));

        bytes4[] memory six = _theSix();
        bytes4[] memory onAppeal = loupe.facetFunctionSelectors(appealAddr);
        bytes4[] memory onRegistry = loupe.facetFunctionSelectors(registryAddr);

        assertEq(onAppeal.length, 6, "the appeal facet does not hold exactly the six");
        // ⚠️ TWENTY-SEVEN AGAIN SINCE THE EVENING OF 8 NOVEMBER 2026, by the
        // arithmetic written out at
        // `test_BeforeTheCutOneAddressHoldsAllThirtyThree`: the registry
        // mounted twenty-seven on the day of the cut, the entry bond added two
        // that morning and both left for ArbiterApplicationsFacet that
        // evening. 33 - 6 = 27, and the subtraction is the property this line
        // is about -- the six LEFT the registry and nothing else moved with
        // them.
        assertEq(onRegistry.length, 27, "the registry does not hold exactly what it compiles, less the six, after the cut");

        for (uint256 i = 0; i < six.length; i++) {
            assertEq(
                loupe.facetAddress(six[i]),
                appealAddr,
                "an appeal door still answers from somewhere other than the new facet"
            );
            assertTrue(_has(onAppeal, six[i]), "the new facet's group is missing one of the six");
            assertFalse(
                _has(onRegistry, six[i]),
                "the registry still ROUTES an appeal selector after the cut - the split is on paper only"
            );
        }

        assertEq(
            loupe.facetFunctionSelectors(preSplitHost).length,
            0,
            "the pre-split host still routes something - a Replace left an address behind"
        );
        assertTrue(registryAddr != appealAddr, "the cut put both groups on one address");
    }

    /// The door answers from the new facet's OWN BODY, proved by the VALUE of
    /// its refusal rather than by "it did not hit the fallback". `raiseAppeal`
    /// on the zero address is `ArbiterZeroAddress()`, which is the FIRST line of
    /// that function and is reachable from nothing else on this diamond.
    function test_TheMovedDoorRefusesByValueFromItsNewHome() public {
        (, address appealAddr) = _performTheSplitCut();
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddress(bytes4(0x6d35b861)),
            appealAddr,
            "raiseAppeal is not routed to the new facet"
        );
        vm.expectRevert(ArbiterRegistryFacet.ArbiterZeroAddress.selector);
        ArbiterAppealFacet(address(diamond)).raiseAppeal(address(0));
    }

    /// ⚠️ THE FACET COUNT MOVES BY EXACTLY ONE, and that is the whole cost of
    /// the split in the proxy's routing table: one host leaves, two arrive.
    function test_TheCutCostsExactlyOneFacetAddress() public {
        uint256 before_ = IDiamondLoupe(address(diamond)).facetAddresses().length;
        _performTheSplitCut();
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddresses().length,
            before_ + 1,
            "the split did not cost exactly one facet address"
        );
    }

    /// ⚠️ ONE SELECTOR CLAIMED BY TWO FACETS IS REFUSED BY THE DIAMOND, BY
    /// VALUE. This is the scene the designated mutation of this work is held
    /// against: if an appeal door were put back on the registry and left in the
    /// appeal facet, the cut that mounted both groups would name one selector
    /// twice. `Add` refuses the second claim with `Diamond: selector exists`,
    /// and the refusal takes the WHOLE diamondCut down, not one function.
    function test_OneSelectorClaimedByTwoFacetsTakesTheWholeCutDown() public {
        bytes4[] memory six = _theSix();
        bytes4[] memory alsoRaise = new bytes4[](1);
        alsoRaise[0] = six[0]; // raiseAppeal, claimed a second time

        IDiamondCut.FacetCut[] memory bad = new IDiamondCut.FacetCut[](2);
        bad[0] = IDiamondCut.FacetCut(
            address(new ArbiterAppealFacet()), IDiamondCut.FacetCutAction.Add, _oneFreshSelector()
        );
        bad[1] = IDiamondCut.FacetCut(
            address(new ArbiterRegistryFacet()), IDiamondCut.FacetCutAction.Add, alsoRaise
        );
        vm.expectRevert(bytes("Diamond: selector exists"));
        IDiamondCut(address(diamond)).diamondCut(bad, address(0), "");

        // And the refused cut changed nothing: the first group's selector is
        // not mounted either, which is what "the whole cut" means.
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddress(_oneFreshSelector()[0]),
            address(0),
            "the first group of a refused cut landed anyway"
        );
    }

    /// A selector this diamond does not route, used as the first group of the
    /// refused cut above so that its absence afterwards is observable.
    /// `getDaoThreshold()` is not in this stand's arbiter mount only if the
    /// list says so, so a bytes4 nobody claims is used instead.
    function _oneFreshSelector() internal pure returns (bytes4[] memory one) {
        one = new bytes4[](1);
        one[0] = bytes4(0xdeadbeef);
    }

    /// ⚠️ AND `Replace` ON AN UNMOUNTED SELECTOR IS THE OTHER HALF OF THE SAME
    /// TRAP, measured here rather than assumed from the EIP: a split filed as
    /// `Add` instead of `Replace` would die on the first element.
    function test_AddOnAMountedAppealSelectorIsRefusedByValue() public {
        bytes4[] memory one = new bytes4[](1);
        one[0] = bytes4(0x6d35b861);
        IDiamondCut.FacetCut[] memory bad = new IDiamondCut.FacetCut[](1);
        bad[0] = IDiamondCut.FacetCut(
            address(new ArbiterAppealFacet()), IDiamondCut.FacetCutAction.Add, one
        );
        vm.expectRevert(bytes("Diamond: selector exists"));
        IDiamondCut(address(diamond)).diamondCut(bad, address(0), "");
    }

    /// Both facets fit under EIP-170 after the split, read off the deployed
    /// code of the addresses this stand actually cut to — not off an artifact.
    function test_BothFacetsFitUnderEip170() public {
        (address registryAddr, address appealAddr) = _performTheSplitCut();
        uint256 reg = registryAddr.code.length;
        uint256 app = appealAddr.code.length;
        assertLt(reg, 24577, "the registry is over EIP-170 after the split");
        assertLt(app, 24577, "the appeal facet is over EIP-170");
        // The split exists to buy room. Named as a floor rather than an
        // equality so that ordinary growth does not red this line, and high
        // enough that losing the room this work bought would.
        assertGt(24576 - reg, 4096, "the split did not leave the registry at least 4 KiB of room");
    }
}
