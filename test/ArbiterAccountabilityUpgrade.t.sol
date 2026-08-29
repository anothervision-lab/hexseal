// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A gate on the cut script script/UpgradeArbiterAccountability.s.sol.
//
// The script declares three selector lists by hand. Hands make mistakes, and the
// price of a mistake here is a cut that mounted the wrong thing, discovered only
// on chain. So the lists are compared against the real ABI, read out of the
// compiled artifact (fs_permissions in foundry.toml already opens ./out for
// reading for the sake of the DeployFullSelectors suite; this file uses the same
// device).
//
// ⚠️ THIS FILE HOLDS A LOCK THAT MOVED HERE ON 15 AUGUST 2026.
// The first piece of the accountability work removed
// test_ReplaceAndAddCoverWholeFacet from the PresentationRecordUpgrade suite: it
// compared the lists of an ALREADY EXECUTED cut against a fresh facet ABI and went
// red at any growth of the facet while saying nothing. The removal was accepted
// CONDITIONALLY: the lock's live role — "an under-mounted or phantom selector" —
// had to move to a cut that has yet to run. Here it is:
//   test_ReplaceAndAddCoverWholeRegistryABI      (not one selector is forgotten)
//   test_NoPhantomSelectorInEitherList           (not one is superfluous)
// Each of them says below what disappears from the behaviour if it is removed.

import "forge-std/Test.sol";
import {UpgradeArbiterAccountability} from "../script/UpgradeArbiterAccountability.s.sol";
import {ArbiterProvenanceInit} from "../script/ArbiterProvenanceInit.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterChainCensus} from "./ArbiterChainCensus.sol";
import "../src/DiamondProxy.sol";

/// A double of the bare button: a contract that REALLY answers
/// removeArbiter(address). It exists for exactly one purpose — to show that before
/// the cut the call went through and after it stopped. The real
/// ArbiterRegistryFacet no longer contains that function (it was deleted), so a
/// selector mounted onto it would revert before the cut too, and the comparison
/// "was alive → became dead" would degenerate into "dead → dead".
contract LegacyRemoveArbiterStub {
    event LegacyRemoveArbiterCalled(address arbiter);

    function removeArbiter(address arbiter) external {
        emit LegacyRemoveArbiterCalled(arbiter);
    }
}

/// A double that answers getSuspensionWindow() with THE WRONG number — it proves
/// by measurement that the post-flight check compares the VALUE and not "the call
/// did not revert".
contract WrongSuspensionWindowStub {
    function getSuspensionWindow() external pure returns (uint256) {
        return 48 hours;
    }
}

contract ArbiterAccountabilityUpgradeTest is Test, ArbiterChainCensus {
    UpgradeArbiterAccountability internal upgrade;

    /// The bare button, named by THE TEXT OF ITS SIGNATURE rather than by
    /// `upgrade.removeSelectors()[0]`. The bench has no right to take even one
    /// selector from the cut's lists — otherwise it would again derive the thing
    /// being checked from the thing doing the checking.
    bytes4 internal constant NAKED_REMOVE_ARBITER = bytes4(keccak256("removeArbiter(address)"));

    /// ⚠️ WHAT THE FACET GREW **AFTER** THIS CUT WAS SIGNED, written down by
    /// hand, by SIGNATURE TEXT and never taken from the script's own lists.
    ///
    /// This cut ran on 21 August 2026 (block 45 781 975). Its lists are a
    /// record of what went into the chain that day and must never be edited
    /// afterwards — editing them would make the script lie about a transaction
    /// that has already happened. But the facet keeps growing, and the lock
    /// below compares those frozen lists against TODAY'S compiled ABI. Without
    /// naming the growth, the lock reddens on every later addition and says
    /// nothing useful — which is exactly the defect the old
    /// test_ReplaceAndAddCoverWholeFacet was removed for.
    ///
    /// So the growth is named instead of folded in. Each entry is held to two
    /// things below: it must be in the facet's ABI today (a stale exemption
    /// dies), and it must be in NEITHER group (an exemption cannot quietly
    /// cover something the cut did mount).
    ///
    ///   • acceptDAOAddress() / getPendingDAOAddress() —
    ///     26 August 2026: setDAOAddress became a proposal and the named
    ///     successor takes office by his own transaction.
    ///   • setDisputeDiscount(uint256) / getDisputeDiscount() —
    ///     29 August 2026: the arbiter vault takes a fixed amount off the
    ///     dispute top-up, and the size of it is a stored number rather than a
    ///     constant, because the protocol has seen zero disputes and three
    ///     dollars is a starting point.
    function _grownAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](4);
        sels[0] = bytes4(keccak256("acceptDAOAddress()"));
        sels[1] = bytes4(keccak256("getPendingDAOAddress()"));
        sels[2] = bytes4(keccak256("setDisputeDiscount(uint256)"));
        sels[3] = bytes4(keccak256("getDisputeDiscount()"));
    }

    /// The same thing for the OTHER facet, which until 29 August 2026 had not
    /// grown at all since this cut and therefore needed no list.
    ///
    ///   • getDisputeSubsidy(address) — a bare read of how much of
    ///     a funded top-up came out of the vault. The field it reads belongs to
    ///     ArbiterRegistryFacet, which writes it; the READ is mounted on this
    ///     facet because the registry stands 90 bytes under the EIP-170 ceiling.
    function _grownAccountabilityAfterThisCut() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("getDisputeSubsidy(address)"));
    }

    /// The arbiter storage namespace, ERC-7201 (ArbiterRegistryStorage.POSITION):
    ///   keccak256(abi.encode(uint256(keccak256("hexseal.arbiterregistry.storage")) - 1))
    ///     & ~bytes32(uint256(0xff))
    /// The same one as in the ArbiterRemovalForCause suite. (The formula in this
    /// comment was corrected in review — the value was right, the description lied.)
    bytes32 constant ARB_POS = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    /// seatedBy is slot 25 and seatedCountBy is 26. They are not taken on trust: the
    /// offset is proved by a round-trip measurement in
    /// test_SeatedBySlotOffsetIsProvenByGetter.
    uint256 constant SLOT_SEATED_BY = 25;
    uint256 constant SLOT_SEATED_COUNT_BY = 26;

    function setUp() public {
        upgrade = new UpgradeArbiterAccountability();
    }

    // ── Ground truth: read straight out of the compiled artifact — the same
    //    device as _abiSelectors in the DeployFullSelectors suite ───────────
    function _abiSelectors(string memory contractName) internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(string.concat("out/", contractName, ".sol/", contractName, ".json"));
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; i++) out[i] = bytes4(keccak256(bytes(sigs[i])));
    }

    function _contains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    // ════════════════════════════════════════════════════════════════════
    // THE LISTS AGAINST THE COMPILED ABI
    // ════════════════════════════════════════════════════════════════════

    /// THE MOVED LOCK, first half: the union of Replace and Add covers the
    /// ArbiterRegistryFacet ABI IN FULL.
    ///
    /// What disappears from the behaviour if this is removed: a selector forgotten in
    /// both lists stays mounted on the OLD facet address — half the diamond runs on
    /// new code and half on old, over one and the same storage, to which this work
    /// appended new fields. The worst possible outcome of a cut, and from outside it
    /// looks like "it all went through, the transaction is green".
    /// ⚠️ REWRITTEN WHEN THE FACETS WERE SPLIT, AND STRENGTHENED RATHER THAN WEAKENED.
    ///
    /// The earlier version knew one facet and added up `replaceSelectors() +
    /// addRegistrySelectors()`, comparing the sum against the registry's ABI. After
    /// fourteen readers moved into the accountability facet that sum stopped being
    /// meaningful: the common Replace now contains selectors of BOTH facets.
    ///
    /// The new version checks MORE than the old one: each of the four groups is
    /// compared against ITS OWN facet BY NAME and BY COUNT. So what is pinned now is
    /// not only "the selector is not forgotten" but "the selector lies in the group
    /// whose address implements it" — precisely the drift this work made possible for
    /// the first time.
    ///
    /// What disappears if this is removed: a selector forgotten in both groups stays
    /// mounted on the OLD facet address — half the diamond runs on new code and half
    /// on old, over one storage. And a selector that landed in ANOTHER facet's group
    /// gets mounted onto an address that does not implement it: diamondCut does not
    /// revert on that (it checks only "the address is different and has code"), and
    /// the call starts reverting on chain.
    function test_ReplaceAndAddCoverWholeRegistryABI() public view {
        _assertGroupsCoverFacetExactly(
            "ArbiterRegistryFacet",
            upgrade.replaceRegistrySelectors(),
            upgrade.addRegistrySelectors(),
            _grownAfterThisCut()
        );
        _assertGroupsCoverFacetExactly(
            "ArbiterAccountabilityFacet",
            upgrade.replaceAccountabilitySelectors(),
            upgrade.addAccountabilitySelectors(),
            _grownAccountabilityAfterThisCut()
        );
    }

    /// The exemption list is held to its own two conditions, in its own test so
    /// that a failure names which one broke.
    ///
    /// What disappears if this is removed: the exemption above would become
    /// an unchecked hole — a selector could be dropped out of the cut's lists
    /// and parked here, and the coverage lock would call the cut complete.
    function test_TheGrowthExemptionIsRealAndCoversNothingTheCutMounted() public view {
        bytes4[] memory grown  = _grownAfterThisCut();
        bytes4[] memory abiSels = _abiSelectors("ArbiterRegistryFacet");

        for (uint256 i = 0; i < grown.length; i++) {
            assertTrue(
                _contains(abiSels, grown[i]),
                "the exemption is stale: this function is no longer in the facet ABI"
            );
            assertFalse(
                _contains(upgrade.replaceRegistrySelectors(), grown[i]),
                "the exemption covers a selector the cut REALLY mounted (Replace)"
            );
            assertFalse(
                _contains(upgrade.addRegistrySelectors(), grown[i]),
                "the exemption covers a selector the cut REALLY mounted (Add)"
            );
        }

        // And the same for the second facet, by the same two conditions.
        bytes4[] memory grownAcc = _grownAccountabilityAfterThisCut();
        bytes4[] memory accAbi   = _abiSelectors("ArbiterAccountabilityFacet");
        for (uint256 i = 0; i < grownAcc.length; i++) {
            assertTrue(
                _contains(accAbi, grownAcc[i]),
                "the exemption is stale: this function is no longer in the accountability facet ABI"
            );
            assertFalse(
                _contains(upgrade.replaceAccountabilitySelectors(), grownAcc[i]),
                "the exemption covers an accountability-facet selector the cut mounted (Replace)"
            );
            assertFalse(
                _contains(upgrade.addAccountabilitySelectors(), grownAcc[i]),
                "the exemption covers an accountability-facet selector the cut mounted (Add)"
            );
        }
    }

    /// The union of the two groups of ONE facet must equal its ABI — by name in both
    /// directions and by count. The count here is not decorative: without it a list
    /// with a repeat would pass the by-name check.
    /// ⚠️ `grown` arrives as a PARAMETER rather than being taken here: each facet has
    /// its own list of what grew after the cut, and the earlier version passed the
    /// registry's to both — so for the accountability facet the deduction was the
    /// wrong one. While that one was not growing there was no difference; since
    /// 29 August 2026 there is.
    function _assertGroupsCoverFacetExactly(
        string memory facetName,
        bytes4[] memory replaceGroup,
        bytes4[] memory addGroup,
        bytes4[] memory grown
    ) internal view {
        bytes4[] memory abiSels = _abiSelectors(facetName);
        assertGt(abiSels.length, 0, "the facet ABI is empty: there is nothing to read");

        // Not one facet selector is forgotten — except what grew AFTER the cut, see
        // _grownAfterThisCut and its own test.
        for (uint256 i = 0; i < abiSels.length; i++) {
            if (_contains(grown, abiSels[i])) continue;
            assertTrue(
                _contains(replaceGroup, abiSels[i]) || _contains(addGroup, abiSels[i]),
                string.concat("a selector landed in neither Replace nor Add: ", facetName)
            );
        }
        // Not one selector in a group belongs to another facet.
        for (uint256 i = 0; i < replaceGroup.length; i++) {
            assertTrue(
                _contains(abiSels, replaceGroup[i]),
                string.concat("the Replace group carries another facet's selector: ", facetName)
            );
        }
        for (uint256 i = 0; i < addGroup.length; i++) {
            assertTrue(
                _contains(abiSels, addGroup[i]),
                string.concat("the Add group carries another facet's selector: ", facetName)
            );
        }
        // And by count — otherwise a repeat inside a group would pass both checks above.
        uint256 exempt;
        for (uint256 i = 0; i < abiSels.length; i++) if (_contains(grown, abiSels[i])) exempt++;
        assertEq(
            replaceGroup.length + addGroup.length, abiSels.length - exempt,
            string.concat("Replace+Add does not match the ABI by selector count: ", facetName)
        );
    }

    /// Add covers the ArbiterAccountabilityFacet ABI in full.
    ///
    /// What disappears if this is removed: a forgotten Add means a function that is
    /// not in the diamond. The client calls it and gets "Diamond: function not
    /// found". A dead button, and the news comes from a person who pressed it.
    function test_AddCoversWholeAccountabilityABI() public view {
        bytes4[] memory addAcc     = upgrade.addAccountabilitySelectors();
        bytes4[] memory replaceAcc = upgrade.replaceAccountabilitySelectors();
        bytes4[] memory abiSels    = _abiSelectors("ArbiterAccountabilityFacet");

        // ⚠️ The accountability facet now arrives in TWO groups rather than one.
        // Eleven relocated readers are already mounted on chain, so they travel by
        // Replace onto the new address; the other twenty are still Add. Demanding
        // "the whole ABI lies in Add" would become untrue; demanding "the whole ABI
        // lies in the union" is exactly the same strength as before.
        // ⚠️ A deduction of exactly the same kind as the registry's above: this facet
        // also grows AFTER the signed cut, and the cut's lists must not be edited —
        // they are a record of a transaction that happened. What grew is named
        // explicitly in _grownAccountabilityAfterThisCut and held to the same two
        // conditions.
        bytes4[] memory grownAcc = _grownAccountabilityAfterThisCut();
        assertEq(
            addAcc.length + replaceAcc.length, abiSels.length - grownAcc.length,
            "the number of selectors being mounted does not match the new facet ABI"
        );
        for (uint256 i = 0; i < abiSels.length; i++) {
            if (_contains(grownAcc, abiSels[i])) continue;
            assertTrue(
                _contains(addAcc, abiSels[i]) || _contains(replaceAcc, abiSels[i]),
                "a selector of the new facet is forgotten in both Add and Replace"
            );
        }

        // The full addSelectors() must contain the whole Add half — the pre-flight
        // (those selectors must NOT be mounted) and the final count take from it. The
        // Replace half is not in it by definition: it is already on chain.
        bytes4[] memory addAll = upgrade.addSelectors();
        for (uint256 i = 0; i < addAcc.length; i++) {
            assertTrue(_contains(addAll, addAcc[i]), "a selector of the new facet was lost from the common Add list");
        }
    }

    /// All 24 selectors being added are named by LITERAL SIGNATURES rather than by
    /// `.selector` from the same contracts. The device is taken from the neighbouring
    /// PresentationRecordUpgrade suite: comparing `.selector` against `.selector` is
    /// a tautology, because on a rename both sides travel together and the test stays
    /// green. Here the facet is on the left and the text of the signature on the
    /// right — the text the client and the relayer depend on — so a divergence must
    /// go red.
    ///
    /// Why Add specifically and not the 63 Replace as well: Replace already has an
    /// independent oracle, and a stronger one than text — THE LIVE CHAIN. A renamed
    /// function gives a selector that is not in the diamond, and the checkReplaceGroup
    /// pre-flight goes red on the very first run. Add has no such oracle by
    /// construction: those selectors must be absent from the chain BOTH BEFORE AND
    /// AFTER a rename, and the pre-flight is equally content with either. So the
    /// textual comparison is needed exactly where the chain stays silent (found in
    /// review).
    ///
    /// What disappears if this is removed: a rename or a change of signature (an extra
    /// argument, uint256 instead of bytes32) would go through in silence — the chain
    /// would mount the new selector while the client went on calling the old one and
    /// got "Diamond: function not found".
    function test_AddSelectorsMatchLiteralSignatures() public view {
        string[] memory regSigs = new string[](3);
        regSigs[0] = "getChiefBloc()";
        regSigs[1] = "getMaxClaimsPerArbiter()";
        regSigs[2] = "getMaxArbiterMistakes()";

        string[] memory accSigs = new string[](24);
        accSigs[0]  = "suspendArbiter(address)";
        accSigs[1]  = "liftSuspension(address)";
        accSigs[2]  = "isSuspended(address)";
        accSigs[3]  = "getSuspendedUntil(address)";
        accSigs[4]  = "getSuspensionWindow()";
        accSigs[5]  = "removeArbiterForCause(address,uint8,bytes32,address,string)";
        accSigs[6]  = "getMistakeThreshold()";
        accSigs[7]  = "getMaxArbiterMistakesMirror()";
        accSigs[8]  = "getDaoThresholdMirror()";
        accSigs[9]  = "proposeRemoval(address,uint8,bytes32,string)";
        accSigs[10] = "withdrawProposal(address)";
        accSigs[11] = "getRemovalProposal(address)";
        accSigs[12] = "hasLiveProposal(address)";
        accSigs[13] = "getProposalTTL()";
        accSigs[14] = "respondToRemoval(bytes32,string)";
        accSigs[15] = "getRemovalReply(address)";
        accSigs[16] = "getArbiterStanding(address)";
        // Three readers moved out of the registry and are NOT YET mounted, so they
        // stayed Add — merely in a different list and onto a different address.
        accSigs[17] = "getSeatedBy(address)";
        accSigs[18] = "getSeatedCountBy(address)";
        accSigs[19] = "getCleanVerdicts(address)";
        // The cause in words: the ceiling on words is in BYTES. The three signatures
        // above were rewritten by the same work — the accusation and the defence each
        // gained a string, and the on-chain signature changed with it.
        accSigs[20] = "getMaxReasonBytes()";
        // The 48-hour pause (design of 17 August 2026): the reading
        // of REMOVAL_DELAY. The signature is written out by hand here on
        // purpose — deriving it from the facet type would compare the script
        // with itself.
        accSigs[21] = "getRemovalDelay()";
        // The quiet door leads into the common one (18 August 2026):
        // the button anyone may press once the chain's own accusation has sat.
        // ONE argument, and the literal here says so — a second parameter would
        // change the selector, and this line is the only place that would
        // notice before the frontend called a function the diamond does not
        // have.
        accSigs[22] = "executeChainRemoval(address)";
        // The other half of the fraction (21 August 2026): how many
        // of this arbiter's verdicts were overturned, over his whole service.
        // Spelled out by hand for the same reason as the two above — taking it
        // from the facet type would compare the script with itself, and the
        // frontend calls this by TEXT.
        accSigs[23] = "getOverturnedVerdicts(address)";

        bytes4[] memory declaredReg = upgrade.addRegistrySelectors();
        assertEq(declaredReg.length, regSigs.length, "Add-registry: the selector count diverged from the signature count");
        for (uint256 i = 0; i < regSigs.length; i++) {
            assertTrue(
                _contains(declaredReg, bytes4(keccak256(bytes(regSigs[i])))),
                "Add-registry: a signature is missing from the selectors being added"
            );
        }

        bytes4[] memory declaredAcc = upgrade.addAccountabilitySelectors();
        assertEq(declaredAcc.length, accSigs.length, "Add-accountability: the selector count diverged from the signature count");
        for (uint256 i = 0; i < accSigs.length; i++) {
            assertTrue(
                _contains(declaredAcc, bytes4(keccak256(bytes(accSigs[i])))),
                "Add-accountability: a signature is missing from the selectors being added"
            );
        }
    }

    /// THE MOVED LOCK, second half: neither Replace nor Add carries a selector that
    /// is in neither of the two ABIs.
    ///
    /// What disappears if this is removed: a typo in a list mounts a phantom selector.
    /// A Replace onto an address that does not implement it does NOT revert
    /// (DiamondCutLib checks only "the address is different and has code"), so the cut
    /// would go through green while the diamond kept an entry leading nowhere forever
    /// — it can only be taken out by a separate cut with a Remove.
    function test_NoPhantomSelectorInEitherList() public view {
        bytes4[] memory reg = _abiSelectors("ArbiterRegistryFacet");
        bytes4[] memory acc = _abiSelectors("ArbiterAccountabilityFacet");

        bytes4[] memory replaceSels = upgrade.replaceSelectors();
        for (uint256 i = 0; i < replaceSels.length; i++) {
            assertTrue(
                _contains(reg, replaceSels[i]) || _contains(acc, replaceSels[i]),
                "Replace: the selector is in neither of the two facets: a phantom"
            );
        }

        bytes4[] memory addSels = upgrade.addSelectors();
        for (uint256 i = 0; i < addSels.length; i++) {
            assertTrue(
                _contains(reg, addSels[i]) || _contains(acc, addSels[i]),
                "Add: the selector is in neither of the two facets: a phantom"
            );
        }
    }

    /// removeArbiter must be in the REMOVAL list and nowhere else. The selector is
    /// computed independently, from the keccak of the signature: comparing a literal
    /// against the same literal would be a tautology.
    ///
    /// What disappears if this is removed: without a Remove the selector stays mounted
    /// on the old address, and the bare button goes on removing an arbiter with no
    /// cause, no record of who pressed it and a refund of the bond — exactly what this
    /// whole piece of work was done to eliminate.
    function test_RemoveArbiterIsInRemoveListAndNowhereElse() public view {
        bytes4 naked = bytes4(keccak256("removeArbiter(address)"));

        bytes4[] memory removeSels = upgrade.removeSelectors();
        assertEq(removeSels.length, 1, "exactly one selector is removed");
        assertEq(removeSels[0], naked, "what is removed is the bare removeArbiter");

        assertFalse(
            _contains(upgrade.replaceSelectors(), naked),
            "a selector being removed cannot be replaced at the same time"
        );
        assertFalse(
            _contains(upgrade.addSelectors(), naked),
            "a selector being removed cannot be added at the same time"
        );

        // And it really is no longer in the facet's code — otherwise removing the
        // selector while the function lives would mean merely a severed entrance.
        assertFalse(
            _contains(_abiSelectors("ArbiterRegistryFacet"), naked),
            "removeArbiter is still in the facet ABI, so it is too early to remove its selector"
        );
    }

    /// Replace and Add do not intersect, and there are no repeats within either.
    ///
    /// What disappears if this is removed: diamondCut would reject the whole cut with
    /// "Diamond: selector exists" — but that would be learned from a production
    /// transaction, after two facets had already been broadcast.
    function test_NoSelectorNamedTwiceAcrossLists() public view {
        bytes4[] memory replaceSels = upgrade.replaceSelectors();
        bytes4[] memory addSels     = upgrade.addSelectors();

        bytes4[] memory all = new bytes4[](replaceSels.length + addSels.length);
        uint256 k;
        for (uint256 i = 0; i < replaceSels.length; i++) all[k++] = replaceSels[i];
        for (uint256 i = 0; i < addSels.length; i++) all[k++] = addSels[i];

        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = i + 1; j < all.length; j++) {
                assertTrue(all[i] != all[j], "a selector is named more than once across Replace/Add");
            }
        }
    }

    /// The common Add is exactly the union of its two halves, with nothing lost or
    /// added. The halves travel to DIFFERENT addresses, so they exist separately; the
    /// common list is read by the pre-flight and the final count, and they must not
    /// drift apart.
    function test_AddSelectorsIsExactlyTheUnionOfItsTwoHalves() public view {
        bytes4[] memory addAll = upgrade.addSelectors();
        bytes4[] memory reg    = upgrade.addRegistrySelectors();
        bytes4[] memory acc    = upgrade.addAccountabilitySelectors();

        assertEq(addAll.length, reg.length + acc.length, "the common Add does not equal the sum of the halves");
        for (uint256 i = 0; i < reg.length; i++) assertTrue(_contains(addAll, reg[i]));
        for (uint256 i = 0; i < acc.length; i++) assertTrue(_contains(addAll, acc[i]));
    }

    /// The composition of buildCuts(): FIVE entries, each with its own action and its
    /// own address. Five and not three, because BOTH Replace AND Add travel to TWO
    /// different addresses — one FacetCut element carries exactly one address (eleven
    /// mounted readers moved to the accountability facet and stayed Replace, because
    /// they are already on chain).
    ///
    /// What disappears if this is removed: a mixed-up address on half of the Replace
    /// would mount eleven readers onto a facet that does not implement them.
    /// diamondCut does NOT revert on that — it checks only "the address is different
    /// and has code". A silent "mounted but does not work" drift.
    function test_BuildCutsShapeAndAddresses() public view {
        address reg = address(0xBEEF);
        address acc = address(0xCAFE);
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(reg, acc);

        assertEq(cuts.length, 5, "buildCuts: exactly five FacetCut entries were expected");

        // ⚠️ THE NUMBERS HERE ARE LITERALS. `upgrade.replaceRegistrySelectors().length`
        // and so on used to stand in their place — a comparison of a list with itself,
        // green whatever its composition. The neighbouring cuts had literals in this
        // place all along (UpgradeFeeModelSelectors: "expected 44", "exactly 14"). They
        // will not catch a swap — that is a count and not an identity, and the two
        // comparisons with the chain census above are there for that — but they do
        // catch a single relocation from group to group by a second lock, independent
        // of the literal signatures.
        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Replace, "cuts[0] must be a Replace");
        assertEq(cuts[0].facetAddress, reg, "Replace-registry: the address must be the new registry");
        assertEq(cuts[0].functionSelectors.length, 52, "Replace-registry: exactly 52 selectors were expected");

        assertTrue(cuts[1].action == IDiamondCut.FacetCutAction.Replace, "cuts[1] must be a Replace");
        assertEq(cuts[1].facetAddress, acc, "Replace-accountability: the address must be the new facet");
        assertEq(cuts[1].functionSelectors.length, 11, "Replace-accountability: exactly 11 selectors were expected");

        assertTrue(cuts[2].action == IDiamondCut.FacetCutAction.Add, "cuts[2] must be an Add");
        assertEq(cuts[2].facetAddress, reg, "Add-registry: the address must be the new registry");
        assertEq(cuts[2].functionSelectors.length, 3, "Add-registry: exactly 3 selectors were expected");

        assertTrue(cuts[3].action == IDiamondCut.FacetCutAction.Add, "cuts[3] must be an Add");
        assertEq(cuts[3].facetAddress, acc, "Add-accountability: the address must be the new facet");
        assertEq(cuts[3].functionSelectors.length, 24, "Add-accountability: exactly 24 selectors were expected");

        // Remove goes last and with a zero address: DiamondCutLib.removeFunctions
        // requires exactly that ("Diamond: remove needs zero address"), and last so
        // that no following action can bring the selector back.
        assertTrue(cuts[4].action == IDiamondCut.FacetCutAction.Remove, "cuts[4] must be a Remove");
        assertEq(cuts[4].facetAddress, address(0), "Remove: the address must be zero");
        assertEq(cuts[4].functionSelectors.length, 1, "Remove: exactly one selector");
    }

    /// The common Replace is exactly the union of its two halves, as the common Add
    /// is. It is not decorative: the checkReplaceGroup pre-flight takes from it, and
    /// that requires ALL the selectors being replaced to sit on ONE address today.
    ///
    /// What disappears if this is removed: a half that dropped out of the common list
    /// would not come under the pre-flight at all — and its being unmounted would come
    /// out as a production "Diamond: selector not found" after two new facets had
    /// already been broadcast.
    function test_ReplaceSelectorsIsExactlyTheUnionOfItsTwoHalves() public view {
        bytes4[] memory all = upgrade.replaceSelectors();
        bytes4[] memory reg = upgrade.replaceRegistrySelectors();
        bytes4[] memory acc = upgrade.replaceAccountabilitySelectors();

        assertEq(all.length, reg.length + acc.length, "the common Replace does not equal the sum of the halves");
        for (uint256 i = 0; i < reg.length; i++) assertTrue(_contains(all, reg[i]), "the registry half was lost from the common Replace");
        for (uint256 i = 0; i < acc.length; i++) assertTrue(_contains(all, acc[i]), "the accountability half was lost from the common Replace");
    }

    // ════════════════════════════════════════════════════════════════════
    // THE REPLACE/ADD SPLIT AGAINST THE CENSUS OF THE LIVE CHAIN
    //
    // Everything above compares the lists against the COMPILED ABI — that is, it
    // answers the question "what can this code do". The ABI does not answer "what is
    // mounted in the diamond TODAY" at all, and that is exactly what determines the
    // boundary between Replace and Add: `Replace` reverts on an unmounted selector,
    // `Add` on a mounted one. There is one oracle here — the census taken from the
    // chain.
    //
    // Both tests below are IDENTITIES, not quantities. A count catches a single
    // relocation and misses a swap: move a mounted selector into Add and an unmounted
    // one into Replace, fixing the literal list of signatures to match, and every
    // number stays as it was (11 and 21, 63+1). Measured: 843 green, 0 red, and the
    // cut rejected outright in production.
    // ════════════════════════════════════════════════════════════════════

    /// IDENTITY ONE: everything the live diamond routes to the old facet is either
    /// replaced or removed by this cut — no more and no less.
    ///
    /// It catches both halves of a swap at once: a selector MOUNTED on chain and moved
    /// into Add disappears from the union (a shortfall); a selector ABSENT from the
    /// chain and moved into Replace turns up as surplus.
    ///
    /// What disappears if this is removed: the production `Replace` gets a selector
    /// that is not in the diamond, and `diamondCut` reverts "Diamond: selector not
    /// found" — the whole cut cancelled by one transaction, after two new facets have
    /// been broadcast. Or, symmetrically, the old address does not empty completely
    /// and half the diamond runs on old code over new storage.
    function test_ReplaceAndRemoveExactlyCoverTheChainCensus() public view {
        bytes4[] memory census = _chainCensus(upgrade.scriptPath());
        bytes4[] memory replaceSels = upgrade.replaceSelectors();
        bytes4[] memory removeSels = upgrade.removeSelectors();

        assertEq(census.length, 64, "the chain census must be 64 selectors");

        // Not one mounted selector is forgotten: it is either replaced or removed.
        for (uint256 i = 0; i < census.length; i++) {
            assertTrue(
                _censusContains(replaceSels, census[i]) || _censusContains(removeSels, census[i]),
                "the selector is mounted on chain but landed in neither Replace nor Remove"
            );
        }
        // And not one being replaced or removed is invented: it must be on chain.
        for (uint256 i = 0; i < replaceSels.length; i++) {
            assertTrue(
                _censusContains(census, replaceSels[i]),
                "Replace aims at a selector that is not on chain, so diamondCut will revert the whole cut"
            );
        }
        for (uint256 i = 0; i < removeSels.length; i++) {
            assertTrue(
                _censusContains(census, removeSels[i]),
                "Remove aims at a selector that is not on chain, so there is nothing to remove"
            );
        }
        // And by count — otherwise a repeat inside Replace would pass both checks above.
        assertEq(
            replaceSels.length + removeSels.length,
            census.length,
            "Replace+Remove does not add up to the census by selector count"
        );
    }

    /// IDENTITY TWO: not one selector being added is on chain yet.
    ///
    /// What disappears if this is removed: a production `Add` on an already mounted
    /// selector reverts "Diamond: selector exists" and cancels the WHOLE cut. The
    /// `checkAddGroupUnmounted` pre-flight exists for exactly that case, but it lives
    /// on the bench and runs once in production; here the same thing is asserted
    /// directly about the data, with no diamond.
    function test_AddSelectorsAreAbsentFromTheChainCensus() public view {
        bytes4[] memory census = _chainCensus(upgrade.scriptPath());
        bytes4[] memory addSels = upgrade.addSelectors();

        for (uint256 i = 0; i < addSels.length; i++) {
            assertFalse(
                _censusContains(census, addSels[i]),
                "Add carries a selector that is already mounted on chain, so Add will revert the whole cut"
            );
        }
    }

    /// THE LOUPE RETURNS THE CENSUS IN FULL — an end-to-end check of the mounting,
    /// NOT a third identity.
    ///
    /// ⚠️ RENAMED AND REWRITTEN. It used to be called
    /// `test_LiveLayoutStandIsTheChainCensusItself` and was declared "the third and
    /// MAIN identity". It is not caught by its own mutation: put `_mountLiveLayout`
    /// back onto `upgrade.replaceSelectors()` — 0 red out of 848 (measured). The
    /// reason is not that the lock is weak but that the claim is TAUTOLOGICAL while
    /// identity one holds (`Replace ∪ Remove == the census`): the bench mounts the
    /// census, the loupe returns what is mounted, and the sets agree by construction.
    ///
    /// The real protection against a cross-swap of Replace/Add is the two identities
    /// ON THE DATA above (test_ReplaceAndRemoveExactlyCoverTheChainCensus and
    /// test_AddSelectorsAreAbsentFromTheChainCensus), and it is proved: that same swap
    /// gives 20 red, with both identities among them by their own messages. A fourth
    /// lock is deliberately NOT built instead — it would guard the same thing a third
    /// time.
    ///
    /// What this test REALLY guards, and why it stays: it is the only one that checks
    /// that the road "census → diamondCut → loupe" goes through IN FULL, with nothing
    /// lost in the mounting. The identities above compare lists against a file and
    /// bring up no diamond at all; if `_mountLiveLayout` mounted the census partially
    /// (a truncated array, a duplicated selector, an `Add` instead of a `Replace` on
    /// part of it), they would not see it, and the benches of every other test would
    /// quietly be working on an incomplete layout.
    function test_MountingTheCensusRoutesEverySelectorToTheOldFacet() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountLiveLayout(diamond);

        bytes4[] memory mounted = IDiamondLoupe(address(diamond)).facetFunctionSelectors(oldFacetAddr);
        bytes4[] memory census = _chainCensus(upgrade.scriptPath());

        assertEq(mounted.length, census.length, "the bench mounted a different number of selectors from the census");
        for (uint256 i = 0; i < census.length; i++) {
            assertTrue(
                _censusContains(mounted, census[i]),
                "a selector from the census was not mounted by the bench"
            );
        }
        for (uint256 i = 0; i < mounted.length; i++) {
            assertTrue(
                _censusContains(census, mounted[i]),
                "the bench mounted a selector that is not in the census"
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════
    // THE BENCH: a local diamond with today's chain layout
    // ════════════════════════════════════════════════════════════════════

    /// A minimal diamond: Cut+Loupe+Ownership. The device comes from the Diamond suite.
    function _deployMinimalDiamond() internal returns (DiamondProxy) {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownFacet = new OwnershipFacet();

        bytes4[] memory cutSels = new bytes4[](1);
        cutSels[0] = IDiamondCut.diamondCut.selector;

        bytes4[] memory loupeSels = new bytes4[](5);
        loupeSels[0] = IDiamondLoupe.facets.selector;
        loupeSels[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        loupeSels[2] = IDiamondLoupe.facetAddresses.selector;
        loupeSels[3] = IDiamondLoupe.facetAddress.selector;
        loupeSels[4] = IERC165.supportsInterface.selector;

        bytes4[] memory ownSels = new bytes4[](4);
        ownSels[0] = OwnershipFacet.transferOwnership.selector;
        ownSels[1] = OwnershipFacet.owner.selector;
        ownSels[2] = OwnershipFacet.acceptOwnership.selector;
        ownSels[3] = OwnershipFacet.pendingOwner.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut(address(cutFacet), IDiamondCut.FacetCutAction.Add, cutSels);
        cuts[1] = IDiamondCut.FacetCut(address(loupeFacet), IDiamondCut.FacetCutAction.Add, loupeSels);
        cuts[2] = IDiamondCut.FacetCut(address(ownFacet), IDiamondCut.FacetCutAction.Add, ownSels);

        return new DiamondProxy(address(this), cuts, address(0), "");
    }

    /// A layout that literally matches Base Sepolia: all 64 arbiter selectors (63
    /// future Replace plus the bare removeArbiter) on ONE facet address. The bare
    /// button is mounted but not implemented — the function was deleted from the code
    /// — which for routing checks is exactly the same thing: addFunctions requires
    /// only that the address have code. Tests that need a LIVE button are served by
    /// _mountLiveLayoutWithWorkingButton.
    ///
    /// ⚠️ MOVED ONTO THE CHAIN CENSUS. `upgrade.replaceSelectors() +
    /// upgrade.removeSelectors()[0]` used to stand here — that is, the bench derived
    /// "what is mounted on chain" FROM THE VERY LIST it checks. A selector moved from
    /// Replace into Add disappeared from the bench together with the list, and
    /// `checkAddGroupUnmounted` honestly failed to find it mounted: the pre-flight
    /// created for exactly that case stayed silent. `checkReplaceGroup` suffered
    /// symmetrically — "all the Replace ones on one address" is true by construction
    /// on a layout assembled from its own argument.
    ///
    /// Now THE CENSUS is mounted — 64 selectors taken from the chain and lying there
    /// as data (test/fixtures/…). The bench stopped depending on the thing under test,
    /// and both pre-flight checks became real.
    ///
    /// What disappears if the list is put back: a cross-swap (a mounted selector in
    /// Add, an unmounted one in Replace, the count unchanged) goes through in silence
    /// again — and rejects the whole cut in one production transaction, after two
    /// facets have been broadcast.
    function _mountLiveLayout(DiamondProxy diamond) internal returns (address oldFacetAddr) {
        ArbiterRegistryFacet oldFacet = new ArbiterRegistryFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(oldFacet), IDiamondCut.FacetCutAction.Add, _chainCensus(upgrade.scriptPath()));
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        oldFacetAddr = address(oldFacet);
    }

    /// The same again, but removeArbiter is mounted on a double that REALLY answers
    /// it: the only way to show the transition "the button worked → the button is
    /// dead", now that the real function is no longer in the code.
    ///
    /// ⚠️ Also from the census: 63 = the census minus the bare button, named by the
    /// text of its signature. Not one selector from the cut's lists.
    function _mountLiveLayoutWithWorkingButton(DiamondProxy diamond)
        internal returns (address oldFacetAddr, address stubAddr)
    {
        ArbiterRegistryFacet oldFacet = new ArbiterRegistryFacet();
        LegacyRemoveArbiterStub stub = new LegacyRemoveArbiterStub();

        bytes4[] memory nakedSel = new bytes4[](1);
        nakedSel[0] = NAKED_REMOVE_ARBITER;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut(
            address(oldFacet),
            IDiamondCut.FacetCutAction.Add,
            _censusWithout(_chainCensus(upgrade.scriptPath()), NAKED_REMOVE_ARBITER)
        );
        cuts[1] = IDiamondCut.FacetCut(address(stub), IDiamondCut.FacetCutAction.Add, nakedSel);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        oldFacetAddr = address(oldFacet);
        stubAddr = address(stub);
    }

    /// Ownership goes to the address derived from PRIVATE_KEY (a two-step handover),
    /// plus the environment run() reads.
    function _armRun(DiamondProxy diamond) internal returns (uint256 pk) {
        pk = 0xA11CE;
        address ownerAddr = vm.addr(pk);
        OwnershipFacet(address(diamond)).transferOwnership(ownerAddr);
        vm.prank(ownerAddr);
        OwnershipFacet(address(diamond)).acceptOwnership();
        // ⚠️ A RACE THROUGH THE PROCESS-GLOBAL vm.setEnv. `vm.setEnv` writes into the
        // PROCESS environment, while forge's suites run in parallel. Three cut benches
        // (ArbiterAccountabilityUpgrade, PresentationRecordUpgrade,
        // ArbiterChatKeyUpgrade) put DIAMOND_ADDRESS here and read it back inside
        // run(). It is harmless precisely because all three put THE SAME address
        // there: their sequence of `new`s before creating the diamond coincides, and
        // so therefore does the nonce.
        //
        // One extra `new` added to any of the three shifts the nonce — the address
        // moves, somebody else's run() goes with the loupe into an unrelated contract,
        // and the full run starts failing with a "random EvmError: Revert" about once
        // in twenty runs, saying nothing about the cause (measured: 2 failures out of
        // 40, against a green single run of 25 out of 25).
        //
        // The race itself is NOT fixed by this line — the real cure is not to pass the
        // address through the environment at all, and that is recorded separately as an
        // open item. This line turns a future flake into a DETERMINISTIC red with a
        // named cause.
        //
        // The address was obtained BY MEASUREMENT (an assertEq probe across all three
        // benches at once) rather than derived from the code: a derived one would move
        // along with the race and stay silent.
        assertEq(
            address(diamond),
            0xc7183455a4C133Ae270771860664b6B7ec320bB1,
            "the diamond's address moved: the bench's nonce shifted, and DIAMOND_ADDRESS "
            "now differs between the three suites in the process; see the comment above"
        );
        vm.setEnv("DIAMOND_ADDRESS", vm.toString(address(diamond)));
        vm.setEnv("PRIVATE_KEY", vm.toString(pk));
    }

    /// An arbiter in the state of the live chain: registered, but with an EMPTY
    /// provenance — the seatedBy field did not exist when they were seated. It is
    /// reproduced by writing raw zeroes over what addArbiter had set.
    function _seatArbiterWithoutProvenance(DiamondProxy diamond, address arb) internal {
        ArbiterRegistryFacet(address(diamond)).addArbiter(arb);
        vm.store(address(diamond), keccak256(abi.encode(arb, uint256(ARB_POS) + SLOT_SEATED_BY)), bytes32(0));
        vm.store(
            address(diamond),
            keccak256(abi.encode(address(this), uint256(ARB_POS) + SLOT_SEATED_COUNT_BY)),
            bytes32(0)
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // PRE-FLIGHT
    // ════════════════════════════════════════════════════════════════════

    /// An honest state: all three pre-flight checks stay silent and find the right
    /// addresses. Without this test the reds from the next three would prove nothing:
    /// showing that a lock reverts on bad input is not enough, one has to show that on
    /// good input it does NOT revert.
    function test_PreflightPassesOnHonestState() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountLiveLayout(diamond);

        address found = upgrade.checkReplaceGroup(upgrade.replaceSelectors(), address(diamond));
        assertEq(found, oldFacetAddr, "checkReplaceGroup did not find the mounted old facet address");

        upgrade.checkAddGroupUnmounted(upgrade.addSelectors(), address(diamond));

        address host = upgrade.checkRemoveGroupMounted(upgrade.removeSelectors(), address(diamond));
        assertEq(host, oldFacetAddr, "the bare button sits on the same facet today");
    }

    /// Remove `checkReplaceGroup(...)` from run() and this test goes red.
    ///
    /// The world is really broken: one of the "remaining" selectors is moved onto an
    /// unrelated facet, as if somebody else's upgrade had passed between runs. In that
    /// state a Replace onto a single new address would take part of the routes to the
    /// wrong place, and without the pre-flight the script would learn of it after the
    /// broadcast.
    function test_RunRevertsWhenReplaceGroupIsSplitAcrossFacets() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);

        ArbiterRegistryFacet strayFacet = new ArbiterRegistryFacet();
        bytes4[] memory stray = new bytes4[](1);
        stray[0] = ArbiterRegistryFacet.getRefundableBounty.selector;
        IDiamondCut.FacetCut[] memory strayCut = new IDiamondCut.FacetCut[](1);
        strayCut[0] = IDiamondCut.FacetCut(address(strayFacet), IDiamondCut.FacetCutAction.Replace, stray);
        IDiamondCut(address(diamond)).diamondCut(strayCut, address(0), "");

        _armRun(diamond);

        vm.expectRevert(bytes("UpgradeArbiterAccountability: the Replace selectors are spread across more than one live facet address"));
        upgrade.run();
    }

    /// Remove `checkAddGroupUnmounted(...)` from run() and this test goes red.
    ///
    /// The world is really broken: one of the new selectors is already mounted (a
    /// repeated run of the script, somebody else's parallel cut). Without the
    /// pre-flight the diamond would revert the whole diamondCut with "Diamond:
    /// selector exists" AFTER two facets had been broadcast — the deployment happened,
    /// the cut did not.
    function test_RunRevertsWhenAnAddSelectorIsAlreadyMounted() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);

        ArbiterAccountabilityFacet stray = new ArbiterAccountabilityFacet();
        bytes4[] memory strayAdd = new bytes4[](1);
        strayAdd[0] = ArbiterAccountabilityFacet.suspendArbiter.selector;
        IDiamondCut.FacetCut[] memory strayCut = new IDiamondCut.FacetCut[](1);
        strayCut[0] = IDiamondCut.FacetCut(address(stray), IDiamondCut.FacetCutAction.Add, strayAdd);
        IDiamondCut(address(diamond)).diamondCut(strayCut, address(0), "");

        _armRun(diamond);

        vm.expectRevert(bytes("UpgradeArbiterAccountability: an Add selector is already mounted somewhere, so Add will revert"));
        upgrade.run();
    }

    /// Remove `checkRemoveGroupMounted(...)` from run() and this test goes red.
    ///
    /// The world is really broken: the bare button is no longer in the diamond
    /// (somebody took it off earlier). Without the pre-flight the Remove would revert
    /// "Diamond: selector not found" and cancel the WHOLE cut — again after the
    /// broadcast. And it is a signal in itself: the chain is not in the state the
    /// script was written for.
    function test_RunRevertsWhenRemoveTargetIsNotMounted() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        ArbiterRegistryFacet oldFacet = new ArbiterRegistryFacet();

        // The census is mounted WITHOUT the bare button — 63 of 64. It is subtracted by
        // the text of its signature rather than by upgrade.removeSelectors(): the bench
        // takes nothing from the cut's lists.
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            address(oldFacet),
            IDiamondCut.FacetCutAction.Add,
            _censusWithout(_chainCensus(upgrade.scriptPath()), NAKED_REMOVE_ARBITER)
        );
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        _armRun(diamond);

        vm.expectRevert(bytes("UpgradeArbiterAccountability: the selector to be removed is not mounted, so there is nothing to remove"));
        upgrade.run();
    }

    // ════════════════════════════════════════════════════════════════════
    // POST-FLIGHT: THE BARE BUTTON
    // ════════════════════════════════════════════════════════════════════

    /// The button worked before the cut and stopped after it. This is the only test
    /// where the transition is visible whole — hence a double that really answers
    /// removeArbiter: with a mounted-but-unimplemented function the comparison would
    /// degenerate into "dead before, dead after" and prove nothing.
    ///
    /// The cut is applied here through buildCuts() directly rather than through run():
    /// the double by definition stands on a DIFFERENT address from the Replace group,
    /// and run() now rejects such a state at the pre-flight (a Remove on somebody
    /// else's facet would tear a piece off it). What is checked here is not the
    /// pre-flight but the bare fact that "there was a route, there is no route"; that
    /// it is run() that calls this check is proved by the neighbouring
    /// test_RunRevertsWhenNakedRemoveArbiterStillAnswers.
    function test_NakedButtonWasAliveBeforeTheCutAndDeadAfter() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        (, address stubAddr) = _mountLiveLayoutWithWorkingButton(diamond);
        assertTrue(stubAddr != address(0));

        (bool okBefore, ) = address(diamond).call(
            abi.encodeWithSignature("removeArbiter(address)", address(0xA1))
        );
        assertTrue(okBefore, "premise: before the cut the bare button must work");

        ArbiterRegistryFacet newReg = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet newAcc = new ArbiterAccountabilityFacet();
        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(address(newReg), address(newAcc)), address(0), ""
        );

        (bool okAfter, ) = address(diamond).call(
            abi.encodeWithSignature("removeArbiter(address)", address(0xA1))
        );
        assertFalse(okAfter, "after the cut the bare button must be dead");
        assertEq(
            IDiamondLoupe(address(diamond)).facetAddress(bytes4(keccak256("removeArbiter(address)"))),
            address(0),
            "after the cut the bare button's selector must lead nowhere"
        );
        // And the script's check on this same world stays silent — that is, it agrees
        // with the world and does not merely revert on a lying one.
        upgrade.assertNakedRemoveArbiterIsDead(address(diamond));
    }

    /// ⚠️ A MEASUREMENT. Remove the line `require(removeHost == oldFacet, ...)` from
    /// run() and precisely this test goes red.
    ///
    /// The world is really broken, and without a single substitution: the bare
    /// removeArbiter is mounted on SOMEBODY ELSE'S facet (an unrelated cut between the
    /// writing of the script and the day of signing). The Replace group is honest and
    /// sits entirely on its own address, all the Add ones are free, the count adds up,
    /// and after the cut the button will be honestly dead — that is, NO other check in
    /// the script sees this. And in such a world the Remove pulls a selector out of
    /// somebody else's facet: a green cut, and a bitten facet.
    function test_RunRevertsWhenRemoveTargetSitsOnAForeignFacet() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayoutWithWorkingButton(diamond); // the button is on the double, not on the registry facet
        _armRun(diamond);

        vm.expectRevert(bytes("pre-flight: removeArbiter sits on a different facet from the Replace group"));
        upgrade.run();
    }

    /// ⚠️ A MEASUREMENT. Remove the line `assertNakedRemoveArbiterIsDead(diamond);`
    /// from run() and precisely this test goes red.
    ///
    /// The world is broken so that run() ITSELF must fail: the cut and the routes are
    /// honest, but a removeArbiter call through the diamond GOES THROUGH — as if the
    /// Remove element had been assembled with the wrong selector (a typo in the literal
    /// 0x3487e08c) and had deleted the wrong thing. In such a world the loupe is
    /// content, the selector count adds up, and the bare button is alive: a removal
    /// with no cause, no record of who pressed it and a refund of the bond. No other
    /// check in run() catches this — which is why it stands on a line of its own.
    function test_RunRevertsWhenNakedRemoveArbiterStillAnswers() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);
        _armRun(diamond);

        vm.mockCall(
            address(diamond),
            abi.encodeWithSelector(bytes4(keccak256("removeArbiter(address)"))),
            bytes("")
        );

        vm.expectRevert(bytes("post-flight: the bare removeArbiter is still routed after the cut"));
        upgrade.run();
    }

    // ════════════════════════════════════════════════════════════════════
    // POST-FLIGHT: THE SMOKE TEST, THE COUNT, THE STORAGE
    // ════════════════════════════════════════════════════════════════════

    /// Remove `assertSuspensionWindowAnswers(diamond)` from run() and this test goes
    /// red. The route is honest: it is the ANSWER that is substituted. Exactly the case
    /// the value is compared for rather than the fact of a return: the client takes the
    /// window from the chain and would draw a person "48 hours", after which the chain
    /// would hold the suspension for another day.
    function test_RunRevertsWhenSuspensionWindowAnswersWrong() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);
        _armRun(diamond);

        vm.mockCall(
            address(diamond),
            abi.encodeWithSelector(ArbiterAccountabilityFacet.getSuspensionWindow.selector),
            abi.encode(uint256(48 hours))
        );

        vm.expectRevert(bytes("post-flight: the suspension window does not answer through the diamond"));
        upgrade.run();
    }

    /// The same lock, but checked on ITS OWN double rather than a mock: the selector is
    /// physically mounted on a contract that answers 48 hours. The route is alive, the
    /// loupe is content, and the value is a lie.
    function test_SuspensionWindowCheckRevertsOnAWrongAnsweringFacet() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        WrongSuspensionWindowStub stub = new WrongSuspensionWindowStub();

        bytes4[] memory sel = new bytes4[](1);
        sel[0] = ArbiterAccountabilityFacet.getSuspensionWindow.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(stub), IDiamondCut.FacetCutAction.Add, sel);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        vm.expectRevert(bytes("post-flight: the suspension window does not answer through the diamond"));
        upgrade.assertSuspensionWindowAnswers(address(diamond));
    }

    /// Remove the final `require(selectorsAfter == selectorsBefore + Add − Remove)`
    /// from run() and this test goes red. What is broken is the census: facets()
    /// answers both reads identically, before and after. The count was bound to move by
    /// +22 and did not move at all — that is, the cut did something other than what it
    /// declared. No other check catches this: the routes are honest one by one, the old
    /// address is empty, the storage is in place, the window answers.
    function test_RunRevertsWhenRoutedSelectorCountDoesNotMove() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);
        _armRun(diamond);

        IDiamondLoupe.Facet[] memory frozen = new IDiamondLoupe.Facet[](0);
        vm.mockCall(address(diamond), abi.encodeWithSelector(IDiamondLoupe.facets.selector), abi.encode(frozen));

        vm.expectRevert(bytes("post-flight: the count of mounted selectors did not move by exactly +Add-Remove"));
        upgrade.run();
    }

    /// Remove `assertStorageContinuity(before, afterCut)` from run() and this test goes
    /// red. The divergence is made the same way as in the neighbouring file:
    /// getVaultBalance() is substituted on the OLD facet address, so the pre-flight
    /// snapshot (the diamond delegates there before the cut) sees 999 while the
    /// post-flight one goes to the new facet and sees the real value. A literal
    /// imitation of what the comparison exists for: one field, read by different code
    /// before and after the cut, has diverged.
    function test_RunRevertsWhenStorageDriftsAcrossTheCut() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountLiveLayout(diamond);
        _armRun(diamond);

        vm.mockCall(
            oldFacetAddr,
            abi.encodeWithSelector(ArbiterRegistryFacet.getVaultBalance.selector),
            abi.encode(uint256(999))
        );

        vm.expectRevert(bytes("post-flight: getVaultBalance() changed across the cut, so the layout may have shifted"));
        upgrade.run();
    }

    /// Remove `assertFacetHoldsNoSelectors(oldFacet, diamond)` from run() and this test
    /// goes red. The world is broken without a single substitution: an EXTRA selector
    /// hangs on the old address, one that is in none of the cut's lists — a trace of an
    /// earlier cut. The Replace will displace the familiar ones, this one will stay, and
    /// the old address will go on serving a live route on top of "already replaced" code.
    function test_RunRevertsWhenOldFacetKeepsALeftoverSelector() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountLiveLayout(diamond);

        bytes4[] memory leftover = new bytes4[](1);
        leftover[0] = bytes4(keccak256("leftoverFromAnOlderCut()"));
        IDiamondCut.FacetCut[] memory leftoverCut = new IDiamondCut.FacetCut[](1);
        leftoverCut[0] = IDiamondCut.FacetCut(oldFacetAddr, IDiamondCut.FacetCutAction.Add, leftover);
        IDiamondCut(address(diamond)).diamondCut(leftoverCut, address(0), "");

        _armRun(diamond);

        vm.expectRevert(bytes("UpgradeArbiterAccountability: the old facet address still holds selectors after the cut"));
        upgrade.run();
    }

    /// Remove any of the three `assertRouted(...)` calls and this test goes red. A real
    /// diamondCut cannot be made to take a selector past the new facet (buildCuts
    /// assembles the routes itself), so it is THE DIRECTORY that lies: the loupe's
    /// answer for one accountability selector is substituted with zero. The pre-flight
    /// demands exactly zero from the Add selectors and stays content, while the
    /// post-flight is bound to see the new facet and does not.
    function test_RunRevertsWhenAnAddSelectorDidNotLandOnTheNewFacet() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);
        _armRun(diamond);

        vm.mockCall(
            address(diamond),
            abi.encodeWithSelector(
                IDiamondLoupe.facetAddress.selector,
                ArbiterAccountabilityFacet.getArbiterStanding.selector
            ),
            abi.encode(address(0))
        );

        vm.expectRevert(bytes("UpgradeArbiterAccountability: a selector did not land on the new facet"));
        upgrade.run();
    }

    // ════════════════════════════════════════════════════════════════════
    // PROVENANCE MIGRATION
    // ════════════════════════════════════════════════════════════════════

    /// The seatedBy offset is proved by a round-trip measurement through the PRODUCTION
    /// getter rather than taken on trust: addArbiter writes the provenance, the getter
    /// sees it, and a raw write of zero into the same slot puts it out. Were the slot
    /// the wrong one, _seatArbiterWithoutProvenance would put nothing out, and the whole
    /// migration bench would be checking an already recorded provenance — that is,
    /// nothing.
    function test_SeatedBySlotOffsetIsProvenByGetter() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);

        address arb = address(0xA12BE12);
        ArbiterRegistryFacet(address(diamond)).addArbiter(arb);

        // The provenance getters arrive with this very cut — the cut comes first.
        ArbiterRegistryFacet newReg = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet newAcc = new ArbiterAccountabilityFacet();
        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(address(newReg), address(newAcc)), address(0), ""
        );

        ArbiterRegistryFacet d = ArbiterRegistryFacet(address(diamond));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedBy(arb), address(this), "addArbiter must record the provenance");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedCountBy(address(this)), 1, "addArbiter must raise the seating counter");

        vm.store(address(diamond), keccak256(abi.encode(arb, uint256(ARB_POS) + SLOT_SEATED_BY)), bytes32(0));
        vm.store(
            address(diamond),
            keccak256(abi.encode(address(this), uint256(ARB_POS) + SLOT_SEATED_COUNT_BY)),
            bytes32(0)
        );
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedBy(arb), address(0), "the seatedBy offset has drifted: the raw write did not land in the field");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedCountBy(address(this)), 0, "the seatedCountBy offset has drifted");
    }

    /// The backfill fills in only what is empty and does not touch what is already
    /// recorded.
    ///
    /// What disappears if the skip of non-empty entries is removed: a repeated run would
    /// inflate seatedCountBy, and the chief's bloc ceiling rests on it — every extra
    /// count gives the chief an extra seat forever.
    function test_BackfillFillsOnlyEmptySeatsAndIsIdempotent() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);

        address blank = address(0xB1A2C);
        address known = address(0xC0FFEE);
        _seatArbiterWithoutProvenance(diamond, blank);
        ArbiterRegistryFacet(address(diamond)).addArbiter(known); // provenance = address(this)

        ArbiterRegistryFacet newReg = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet newAcc = new ArbiterAccountabilityFacet();
        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(address(newReg), address(newAcc)), address(0), ""
        );

        ArbiterRegistryFacet d = ArbiterRegistryFacet(address(diamond));
        address[] memory pending = upgrade.arbitersMissingProvenance(address(diamond));
        assertEq(pending.length, 1, "there is exactly one empty seat");
        assertEq(pending[0], blank);

        address seater = address(0xDEC1DE7);
        ArbiterProvenanceInit init = new ArbiterProvenanceInit();
        IDiamondCut(address(diamond)).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(init),
            abi.encodeCall(ArbiterProvenanceInit.backfillSeatedBy, (pending, seater))
        );

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedBy(blank), seater, "the empty provenance was not filled in");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedBy(known), address(this), "somebody else's provenance was overwritten, which is not allowed");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedCountBy(seater), 1, "the seating counter was not raised");

        // A repeated run over THE SAME list must change nothing.
        IDiamondCut(address(diamond)).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(init),
            abi.encodeCall(ArbiterProvenanceInit.backfillSeatedBy, (pending, seater))
        );
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedCountBy(seater), 1, "a repeated migration inflated the seating counter");
    }

    /// A non-arbiter in the list is a refusal, not a silent skip: writing a provenance
    /// for an outsider means asserting on chain that somebody seated them.
    function test_BackfillRevertsForNonArbiter() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);

        ArbiterRegistryFacet newReg = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet newAcc = new ArbiterAccountabilityFacet();
        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(address(newReg), address(newAcc)), address(0), ""
        );

        address stranger = address(0x5747A9E);
        address[] memory list = new address[](1);
        list[0] = stranger;

        ArbiterProvenanceInit init = new ArbiterProvenanceInit();
        vm.expectRevert(abi.encodeWithSelector(ArbiterProvenanceInit.ProvenanceNotAnArbiter.selector, stranger));
        IDiamondCut(address(diamond)).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(init),
            abi.encodeCall(ArbiterProvenanceInit.backfillSeatedBy, (list, address(0xDEC1DE7)))
        );
    }

    /// Remove `migrateProvenance(diamond, pk)` from run() and this test goes red. What
    /// is measured is the TRACE the migration is bound to leave: after run() an arbiter
    /// with an empty provenance has the owner recorded for them, and the owner's seating
    /// counter equals one. Without the call both would have stayed zero — that is, the
    /// chain would go on calling somebody seated by hand a self-enrolled one.
    function test_RunMigratesProvenanceOfTheSeatedArbiter() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);

        address arb = address(0x42dCd14e);
        _seatArbiterWithoutProvenance(diamond, arb);

        uint256 pk = _armRun(diamond);
        address ownerAddr = vm.addr(pk);

        upgrade.run();

        ArbiterRegistryFacet d = ArbiterRegistryFacet(address(diamond));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedBy(arb), ownerAddr, "the provenance was not filled in by the migration");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedCountBy(ownerAddr), 1, "the owner's seating counter was not raised");
        assertEq(upgrade.arbitersMissingProvenance(address(diamond)).length, 0, "after the migration there must be no empty seats");
    }

    /// The migration does not invent work where there is none: every arbiter has a
    /// provenance, so there will be no second transaction and no foreign record touched.
    function test_RunSkipsMigrationWhenNothingIsMissing() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);

        address arb = address(0xA5EA7ED);
        ArbiterRegistryFacet(address(diamond)).addArbiter(arb); // provenance = address(this)

        uint256 pk = _armRun(diamond);
        upgrade.run();

        ArbiterRegistryFacet d = ArbiterRegistryFacet(address(diamond));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedBy(arb), address(this), "the provenance was overwritten with the owner, which is not allowed");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedCountBy(vm.addr(pk)), 0, "the owner was credited with a seating they did not do");
    }

    /// The emergency entrance works on its own: the cut has landed (a repeated run()
    /// would refuse at the pre-flight — the Add selectors are mounted) and the
    /// provenance is not filled in. What disappears if migrateProvenanceOnly() is
    /// removed: a person whose second transaction did not arrive would be left with no
    /// way to finish it, other than writing a one-off script by hand that same evening.
    function test_MigrateProvenanceOnlyFinishesAnInterruptedRollout() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountLiveLayout(diamond);

        address arb = address(0x42dCd14e);
        _seatArbiterWithoutProvenance(diamond, arb);

        // The cut went through; the second transaction did not.
        ArbiterRegistryFacet newReg = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet newAcc = new ArbiterAccountabilityFacet();
        IDiamondCut(address(diamond)).diamondCut(
            upgrade.buildCuts(address(newReg), address(newAcc)), address(0), ""
        );

        uint256 pk = _armRun(diamond);
        address ownerAddr = vm.addr(pk);
        ArbiterRegistryFacet d = ArbiterRegistryFacet(address(diamond));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedBy(arb), address(0), "premise: the provenance is not filled in yet");

        upgrade.migrateProvenanceOnly();
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedBy(arb), ownerAddr, "the emergency entrance did not fill in the provenance");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedCountBy(ownerAddr), 1, "the seating counter was not raised");

        // A repeated call changes nothing and sends no transactions.
        upgrade.migrateProvenanceOnly();
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedCountBy(ownerAddr), 1, "a repeated emergency entrance inflated the counter");
    }

    // ════════════════════════════════════════════════════════════════════
    // THE FULL CYCLE
    // ════════════════════════════════════════════════════════════════════

    /// Literally run() — not a retelling of its steps but the method itself, with real
    /// vm.envAddress/vm.envUint/vm.startBroadcast, on a locally deployed diamond with
    /// today's chain layout. The diamond is seeded NON-empty before the cut: an arbiter
    /// with no provenance and a non-zero vault — otherwise the storage-continuity check
    /// would compare zeroes with zeroes and would pass even if it were completely
    /// broken.
    ///
    /// The smoke test of the new entrances goes THROUGH THE DIAMOND rather than by a
    /// direct call to the facet: "counts as mounted" and "the route executes the code"
    /// are different things (the class of bug that was deployed, never once fired, and
    /// noticed a month later).
    function test_RunEndToEndOnLocalDiamond() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountLiveLayout(diamond);

        address arb = address(0x42dCd14e);
        _seatArbiterWithoutProvenance(diamond, arb);
        _setVaultBalance(diamond, 777_000_000);

        uint256 pk = _armRun(diamond);
        address ownerAddr = vm.addr(pk);

        uint256 routedBefore = upgrade.totalRoutedSelectors(address(diamond));
        assertEq(routedBefore, 10 + 64, "the bench must reproduce the live layout: 64 arbiter selectors");

        upgrade.run();

        // ── Routes ────────────────────────────────────────────────────────
        upgrade.assertFacetHoldsNoSelectors(oldFacetAddr, address(diamond));

        address newReg = IDiamondLoupe(address(diamond)).facetAddress(ArbiterRegistryFacet.addArbiter.selector);
        address newAcc = IDiamondLoupe(address(diamond)).facetAddress(ArbiterAccountabilityFacet.suspendArbiter.selector);
        assertTrue(newReg != address(0) && newReg != oldFacetAddr, "the registry did not move to a new address");
        assertTrue(newAcc != address(0) && newAcc != newReg, "accountability must be a separate facet");
        // ⚠️ FOUR GROUPS, NOT THREE. The common replaceSelectors() no longer serves
        // here: it contains selectors of BOTH facets, and a check of "all on newReg"
        // would be knowingly false. Each half is compared against ITS OWN address —
        // which is stricter than before, because it pins belonging as well as "it
        // moved".
        upgrade.assertRouted(upgrade.replaceRegistrySelectors(), newReg, address(diamond));
        upgrade.assertRouted(upgrade.replaceAccountabilitySelectors(), newAcc, address(diamond));
        upgrade.assertRouted(upgrade.addRegistrySelectors(), newReg, address(diamond));
        upgrade.assertRouted(upgrade.addAccountabilitySelectors(), newAcc, address(diamond));

        assertEq(
            upgrade.totalRoutedSelectors(address(diamond)),
            routedBefore + upgrade.addSelectors().length - upgrade.removeSelectors().length,
            "the selector count did not move by exactly +Add-Remove"
        );

        // ── The storage survived the cut ──────────────────────────────────
        ArbiterRegistryFacet d = ArbiterRegistryFacet(address(diamond));
        assertEq(d.getArbiters().length, 1, "the arbiter did not survive the cut");
        assertEq(d.getVaultBalance(), 777_000_000, "the vault did not survive the cut");
        assertTrue(d.isRegisteredArbiter(arb), "the arbiter status did not survive the cut");

        // ── The bare button is dead ───────────────────────────────────────
        (bool ok, ) = address(diamond).call(abi.encodeWithSignature("removeArbiter(address)", arb));
        assertFalse(ok, "the bare removeArbiter must be dead after the cut");

        // ── A smoke test of the new entrances THROUGH THE DIAMOND ─────────
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSuspensionWindow(), 72 hours, "the suspension window is not 72 hours");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getProposalTTL(), 14 days, "the proposal lifetime is not two weeks");
        assertFalse(ArbiterAccountabilityFacet(address(diamond)).isSuspended(arb), "a fresh arbiter is not suspended");
        assertFalse(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arb), "there is no proposal against a fresh arbiter");
        assertEq(d.getMaxClaimsPerArbiter(), 10, "the per-arbiter dispute ceiling does not answer");
        assertGt(d.getMaxArbiterMistakes(), 0, "the judging-mistake threshold does not answer");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getCleanVerdicts(arb), 0, "a fresh arbiter's judging service must be zero");

        // The provenance was filled in by the second transaction, and the chief's bloc
        // is counted from it: no chief is appointed, so the bloc is zero, and the
        // seating is credited to the owner.
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedBy(arb), ownerAddr, "the provenance was not migrated");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getSeatedCountBy(ownerAddr), 1, "the owner's seating counter was not raised");
        assertEq(d.getChiefBloc(), 0, "there is no chief, so the bloc must be zero");

        // A writing function of the new facet, through the diamond too. A refusal is
        // expected and is itself the proof that the route executes THE FACET'S code: the
        // diamond's empty fallback would have reverted "Diamond: function not found"
        // rather than with an application error from the facet.
        vm.expectRevert(abi.encodeWithSignature("NothingToAnswer()"));
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(bytes32(uint256(1)), "");
    }

    /// A direct write into vaultBalance (a plain uint256 field, slot POSITION+9). There
    /// is no setter without a USDC transfer, and fundVault() is unreachable here — this
    /// diamond does not mount Factory. The offset is confirmed by reading it back
    /// through the getter right after the write, not on trust.
    function _setVaultBalance(DiamondProxy diamond, uint256 amount) internal {
        vm.store(address(diamond), bytes32(uint256(ARB_POS) + 9), bytes32(amount));
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(), amount,
            "the vaultBalance offset in ArbiterRegistryStorage.Data has drifted"
        );
    }
}
