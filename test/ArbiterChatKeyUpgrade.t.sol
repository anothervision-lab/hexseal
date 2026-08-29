// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {LegacyPreSplitArbiterFacet, ArbiterTwoFacetBench} from "./ArbiterTwoFacetBench.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {UpgradeArbiterChatKey} from "../script/archive/UpgradeArbiterChatKey.s.sol";
import {ArbiterChainCensus} from "./ArbiterChainCensus.sol";
import "../src/DiamondProxy.sol";

/// The same cut, but deploying the "facet from before the accountability split"
/// double.
///
/// ⚠️ Why it exists. The cut was executed on 10 August 2026, when every one of
/// its selectors was implemented by a single ArbiterRegistryFacet. The split of
/// 16 August 2026 moved fourteen readers — including getArbiterChatKeys, on which
/// the FUNCTIONAL SMOKE TEST inside run() itself stands — into
/// ArbiterAccountabilityFacet. On today's source a literal repeat of run() would
/// mount that selector on a facet that does not implement it, and fail on run()'s
/// own post-flight check.
///
/// EXACTLY the facet deployment is substituted and nothing else: the selector
/// lists, the order of actions and the pre- and post-flight checks stay the same
/// and are executed in full. This is an exact reproduction of that day, not a
/// weakened check.
contract UpgradeArbiterChatKeyOnPreSplitFacet is UpgradeArbiterChatKey {
    function _deployRegistryFacet() internal override returns (address) {
        return address(new LegacyPreSplitArbiterFacet());
    }
}

contract ArbiterChatKeyUpgradeTest is Test, ArbiterTwoFacetBench, ArbiterChainCensus {
    UpgradeArbiterChatKey internal upgrade;

    /// ⚠️ EXACTLY ONE `new`. A second contract deployed here shifts the test
    /// contract's nonce and with it the address of the local diamond, and a full
    /// `forge test` starts failing about once in twenty runs through the
    /// process-global `vm.setEnv`. The analysis and the measurement are in the
    /// header of `_presentationCutAddSelectors()` in the chain-census bench.
    function setUp() public {
        upgrade = new UpgradeArbiterChatKeyOnPreSplitFacet();
    }

    /// The old claim entrance is GONE from the facet. A lock against somebody one
    /// day bringing back an overload "for compatibility": a second road to a claim
    /// is a road to a claim without a key.
    ///
    /// What disappears from the behaviour if the fix is removed: it becomes possible
    /// again to take a dispute without publishing a key — the arbiter claims it, has
    /// nothing to read the evidence with, and the case times out with the pot split
    /// in half.
    function test_OldClaimSelectorGone() public pure {
        bytes4 oldSel = bytes4(keccak256("claimDispute(address,bytes32)"));
        bytes4 newSel = bytes4(keccak256("claimDispute(address,bytes32,bytes32,bytes32)"));
        assertTrue(oldSel != newSel, "the selectors coincide: the signature never changed");
        assertEq(
            ArbiterRegistryFacet.claimDispute.selector,
            newSel,
            "the facet returns the wrong selector: an overload remains, or the signature differs"
        );
    }

    // ── Ground truth: read straight out of the compiled artifact — the same
    //    device as _abiSelectors in the DeployFullSelectors suite ───────────
    function _abiSelectors(string memory contractName) internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(string.concat("out/", contractName, ".sol/", contractName, ".json"));
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        out = new bytes4[](sigs.length);
        for (uint256 i; i < sigs.length; i++) out[i] = bytes4(keccak256(bytes(sigs[i])));
    }

    /// 1. ── REMOVED on 14 August 2026 ──────────────────────────────────────
    ///
    /// test_ReplaceAndAddCoverWholeFacet used to stand here: it compared the union
    /// of THIS script's replaceSelectors()+addSelectors() against a fresh
    /// ArbiterRegistryFacet ABI. The cut this file describes was executed on Base
    /// Sepolia on 10 August and will never be repeated, and its selector lists
    /// describe the facet of THAT day forever (56 methods). Any later growth of the
    /// facet — and later work added eight functions, 56 → 64 — turned the test red
    /// while saying nothing about anything: comparing an executed cut against
    /// today's code is meaningless.
    ///
    /// The live role (spotting an under-mounted or phantom selector BEFORE a
    /// rollout) was taken over by exactly the same test against the CURRENT cut —
    /// test_ReplaceAndAddCoverWholeFacet in the PresentationRecordUpgrade suite.
    /// The lock did not weaken: it simply moved to the script that has yet to be
    /// run. The other 22 tests in this file are alive and there is nothing to touch
    /// about them — they check the pre- and post-flight helpers and storage
    /// continuity, that is, logic that does not depend on the facet's growth.

    /// 2. The old entrance is removed and is absent from the new ABI.
    ///
    /// What disappears if this is removed: a second road to a claim remains — one
    /// without a key.
    function test_OldSelectorRemovedAndAbsentFromNewAbi() public view {
        bytes4[] memory removeSels = upgrade.removeSelectors();
        assertEq(removeSels.length, 1, "removeSelectors: expected exactly one selector");
        assertEq(
            removeSels[0],
            bytes4(keccak256("claimDispute(address,bytes32)")),
            "removeSelectors: not the old two-argument claimDispute selector"
        );

        bytes4[] memory abiSels = _abiSelectors("ArbiterRegistryFacet");
        for (uint256 i = 0; i < abiSels.length; i++) {
            assertTrue(
                abiSels[i] != removeSels[0],
                "old claimDispute(address,bytes32) is still present in the compiled facet ABI"
            );
        }
    }

    /// 3. No selector is named twice across the three lists.
    /// diamondCut rejects the addition of one that already exists, so an
    /// intersection of Replace and Add would take the whole rollout down, on the
    /// live diamond.
    ///
    /// What disappears if this is removed: a silent typo instead of a comprehensible
    /// refusal at build time (the diamond on chain would revert the whole cut, but
    /// here it would be discovered only at the real rollout rather than in advance).
    function test_NoSelectorNamedTwiceAcrossLists() public view {
        bytes4[] memory removeSels = upgrade.removeSelectors();
        bytes4[] memory replaceSels = upgrade.replaceSelectors();
        bytes4[] memory addSels = upgrade.addSelectors();

        bytes4[] memory all = new bytes4[](removeSels.length + replaceSels.length + addSels.length);
        uint256 k = 0;
        for (uint256 i = 0; i < removeSels.length; i++) all[k++] = removeSels[i];
        for (uint256 i = 0; i < replaceSels.length; i++) all[k++] = replaceSels[i];
        for (uint256 i = 0; i < addSels.length; i++) all[k++] = addSels[i];

        for (uint256 i = 0; i < all.length; i++) {
            for (uint256 j = i + 1; j < all.length; j++) {
                assertTrue(all[i] != all[j], "a selector is named more than once across Remove/Replace/Add");
            }
        }
    }

    /// The composition of buildCuts(): three actions, the expected lengths and the
    /// address(es) — Remove must be address(0) (the EIP-2535 rule), Replace and Add
    /// the new facet. It checks run()'s own assembly, not only the source lists.
    function test_BuildCutsShapeAndAddresses() public view {
        address facet = address(0xBEEF);
        IDiamondCut.FacetCut[] memory cuts = upgrade.buildCuts(facet);

        assertEq(cuts.length, 3, "buildCuts: expected exactly 3 FacetCut entries");

        assertTrue(cuts[0].action == IDiamondCut.FacetCutAction.Remove, "cuts[0] should be Remove");
        assertEq(cuts[0].facetAddress, address(0), "Remove: facetAddress must be address(0) per EIP-2535");
        assertEq(cuts[0].functionSelectors.length, 1);

        assertTrue(cuts[1].action == IDiamondCut.FacetCutAction.Replace, "cuts[1] should be Replace");
        assertEq(cuts[1].facetAddress, facet, "Replace: facetAddress must be the new facet");
        assertEq(cuts[1].functionSelectors.length, 53);

        assertTrue(cuts[2].action == IDiamondCut.FacetCutAction.Add, "cuts[2] should be Add");
        assertEq(cuts[2].facetAddress, facet, "Add: facetAddress must be the new facet");
        assertEq(cuts[2].functionSelectors.length, 3);
    }

    // ════════════════════════════════════════════════════════════════════
    // Pre/post-flight — proved on a locally deployed diamond, not only on the
    // source lists. A Replace onto an address without the required selector does
    // NOT revert (DiamondCutLib.replaceFunctions checks only "the address is
    // different and has code", not "does it implement the selector") — a silent
    // drift of the "mounted but does not work" kind, exactly the class that already
    // broke fundDispute by reading msg.sender instead of _msgSender(). So the
    // pre/post-flight checks in the script itself have to be proved by measurement
    // rather than taken on trust.
    // ════════════════════════════════════════════════════════════════════

    /// A minimal diamond: Cut+Loupe+Ownership, with no Registry or Factory — they
    /// are not needed, and the selector-routing checks do not touch them. The device
    /// comes from the Diamond suite's setUp().
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

    /// Mounts the "old" (pre-upgrade) layout: 53 selectors from replaceSelectors()
    /// plus the old claim entrance from removeSelectors(), all on ONE new facet
    /// address — precisely the state the script finds on the live chain before the
    /// upgrade. addFunctions (DiamondCutLib.sol) does not check that the address
    /// really implements every selector being mounted, only that it has code, so the
    /// old entrance can be mounted on any deployed ArbiterRegistryFacet without
    /// resurrecting the deleted signature in the sources.
    function _mountOldFacet(DiamondProxy diamond) internal returns (address oldFacetAddr) {
        // ⚠️ The "facet from before the split" double rather than the production
        // ArbiterRegistryFacet: this bench reproduces the chain's layout AT THE
        // MOMENT of that cut — every selector on ONE address — and since then
        // fourteen readers have moved into ArbiterAccountabilityFacet, so no
        // production contract implements them all at once any more. A bare facet
        // would mount (diamondCut requires only the presence of code), but the
        // pre-flight really calls getOpenClaimCount and would revert.
        LegacyPreSplitArbiterFacet oldFacet = new LegacyPreSplitArbiterFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(oldFacet), IDiamondCut.FacetCutAction.Add, _preCutLayout());
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        oldFacetAddr = address(oldFacet);
    }

    /// The chain's layout BEFORE this cut, REWOUND FROM THE CENSUS.
    ///
    /// ⚠️ `upgrade.replaceSelectors() + upgrade.removeSelectors()` used to stand
    /// here — the bench derived "what was mounted on chain" FROM THE VERY LIST it
    /// checks, and the pre-flights agreed with themselves: a lock looking at itself
    /// in the mirror.
    ///
    /// The oracle is the census of the live chain, rewound back through TWO executed
    /// cuts:
    ///   the census of 16 August                                     64
    ///   − the Add of the "chain as a witness" cut (15.08)           −8  → 56
    ///   − the Add of this cut (10.08)                               −3  → 53
    ///   + the Remove of this cut (the old two-argument claimDispute) +1  → 54
    ///
    /// Only the Add and Remove lists of those scripts take part in the rewind, and
    /// both are locked down by literal signatures: eight for the presentation cut
    /// (`_presentationCutAddSelectors()`, compared against that script's production
    /// list by a neighbouring test), one here
    /// (test_OldSelectorRemovedAndAbsentFromNewAbi). `replaceSelectors()`, the very
    /// thing the bench is built for, takes no part in the computation at all.
    ///
    /// ⚠️ THE REWIND WAS REPLACED BY AN OBSERVATION. The layout used to be COMPUTED
    /// by rewinding the census of 16 August two steps. The rewind is correct, but it
    /// is a derivation — and a derivation lives until the first error in the lists it
    /// is made from, and here there are two such lists, not one. The layout is now
    /// READ from a chain snapshot at block 45281830 (the last block before the
    /// transaction of the 10 August cut): 54 selectors on 0x42E9f172…, 167 routes in
    /// total.
    /// The rewind is not thrown away — it is compared against the snapshot in
    /// test_TwoStepRewindMatchesTheChainSnapshot below.
    function _preCutLayout() internal view returns (bytes4[] memory out) {
        out = _chainCensusBefore10Aug(upgrade.scriptPath());
        require(out.length == 54, "the layout before the 10 August cut must be 54 selectors");
    }

    /// Observation against computation, two steps: the chain snapshot of 10 August
    /// must agree with the census of 16 August rewound back through BOTH executed
    /// cuts.
    ///
    /// What disappears if this is removed: two independent sources become one again.
    /// While they are compared, an error in any of the three lists the rewind is made
    /// from (the eight signatures of the presentation cut, and this cut's Add and
    /// Remove) goes red HERE — rather than in a rejected production transaction; and
    /// conversely, a substituted snapshot goes red against the rewind.
    function test_TwoStepRewindMatchesTheChainSnapshot() public view {
        bytes4[] memory afterThisCut = _rewindCut(
            _censusFromFile(CENSUS_PATH, CENSUS_FACET, 64, "script/UpgradeArbiterAccountability.s.sol"),
            _presentationCutAddSelectors(),
            new bytes4[](0)
        );
        // A snapshot of SOMEBODY ELSE'S cut, deliberately as a literal; the analysis
        // is in the `_censusFromFile` docstring: deploying a foreign script for the
        // sake of its name means adding a `new` and bringing the nonce race back,
        // and it adds no protection — a type travels by copy-paste just as a string does.
        _assertSameSelectorSet(
            _chainCensusAfter10Aug("script/UpgradePresentationRecord.s.sol"),
            afterThisCut,
            "the chain snapshot of 14 August",
            "the census rewound by one step"
        );

        _assertSameSelectorSet(
            _chainCensusBefore10Aug(upgrade.scriptPath()),
            _rewindCut(afterThisCut, upgrade.addSelectors(), upgrade.removeSelectors()),
            "the chain snapshot of 10 August",
            "the census rewound by two steps"
        );
    }

    bytes32 constant ARB_POS = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

    /// A direct write into vaultBalance (a plain uint256 field in
    /// ArbiterRegistryStorage.Data, slot POSITION+9). There is no setter without a
    /// USDC transfer, and fundVault() is unreachable here — this diamond does not
    /// mount Factory, and FactoryStorage.usdc == address(0). The offset is confirmed
    /// by the same device as _setTrustedForwarder in the ArbiterChatKey suite —
    /// reading it back through the getter right after the write, not on trust.
    function _setVaultBalance(DiamondProxy diamond, uint256 amount) internal {
        bytes32 slot = bytes32(uint256(ARB_POS) + 9);
        vm.store(address(diamond), slot, bytes32(amount));
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(), amount,
            "the vaultBalance offset in ArbiterRegistryStorage.Data has drifted"
        );
    }

    /// A direct write into openClaimCount[arbiter] (a mapping, slot base
    /// POSITION+13). Giving an arbiter an "open dispute" through a real claimDispute
    /// is impossible here — that needs an Agreement answering
    /// status()/disputedAt()/client()/executor(), and a Registry record, neither of
    /// which this minimal diamond has. The offset is confirmed by reading it back
    /// through getOpenClaimCount(), the same device as above.
    function _setOpenClaimCount(DiamondProxy diamond, address arbiter, uint256 n) internal {
        bytes32 slot = keccak256(abi.encode(arbiter, uint256(ARB_POS) + 13));
        vm.store(address(diamond), slot, bytes32(n));
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(arbiter), n,
            "the openClaimCount offset in ArbiterRegistryStorage.Data has drifted"
        );
    }

    bytes32 constant SEED_BOX_KEY  = bytes32(uint256(0x5eed0001));
    bytes32 constant SEED_SIGN_KEY = bytes32(uint256(0x5eed0002));

    /// A direct write into arbiterBoxKey/arbiterSignKey (mappings, slot bases
    /// POSITION+20/+21). NOT through setArbiterChatKey: that selector, like
    /// getArbiterChatKeys, is mounted only AFTER this very cut — on the live chain
    /// "an arbiter with a key BEFORE the upgrade" is structurally impossible (before
    /// this upgrade there was no way to set a key at all). The write goes here
    /// directly in order to prove something else: that the layout of these two NEW
    /// fields (append-only, added by the same change) survives the replacement of the
    /// facet address in the cut — that is, a replacement of code and not of slots.
    /// It can only be read back AFTER the cut (see the calling test) —
    /// getArbiterChatKeys is not mounted before it.
    function _setChatKeyRaw(DiamondProxy diamond, address arbiter, bytes32 box, bytes32 sign) internal {
        bytes32 boxSlot  = keccak256(abi.encode(arbiter, uint256(ARB_POS) + 20));
        bytes32 signSlot = keccak256(abi.encode(arbiter, uint256(ARB_POS) + 21));
        vm.store(address(diamond), boxSlot, box);
        vm.store(address(diamond), signSlot, sign);
    }

    /// Seats an arbiter with a key and a non-empty vault BEFORE the cut, so that the
    /// pre/post comparison does not compare zeroes with zeroes — without this the
    /// storage-continuity check would be an honest check over an empty space rather
    /// than a check on real data.
    ///
    /// To be called BEFORE ownership of the diamond is handed to another address:
    /// addArbiter is onlyOwnerOrChief, and right after _deployMinimalDiamond the
    /// owner is address(this) (the test contract).
    function _seedPreCutArbiterState(DiamondProxy diamond, address arbiter) internal {
        ArbiterRegistryFacet f = ArbiterRegistryFacet(address(diamond));
        f.addArbiter(arbiter);
        _setVaultBalance(diamond, 777_000_000); // 777 USDC — deliberately neither zero nor a "round" default
        _setChatKeyRaw(diamond, arbiter, SEED_BOX_KEY, SEED_SIGN_KEY);
    }

    /// An honest state: the pre-flight checks pass and return the correct old
    /// address. Without this test the reds from the next two would prove nothing —
    /// showing that a lock reverts on bad input is not enough, one has to show that
    /// it does NOT revert on good input.
    function test_PreflightPassesOnHonestState() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        address found = upgrade.checkReplaceGroup(upgrade.replaceSelectors(), address(diamond));
        assertEq(found, oldFacetAddr, "checkReplaceGroup: did not find the mounted old facet address");

        upgrade.checkRemoveSelectorMounted(upgrade.removeSelectors(), oldFacetAddr, address(diamond));
        upgrade.checkAddGroupUnmounted(upgrade.addSelectors(), address(diamond));
        // Nothing reverted — the point of the test.
    }

    /// What disappears if the fix is removed: the script runs against a diamond where
    /// one of the "remaining" selectors has in fact already moved to another address
    /// (the facet was PARTIALLY upgraded by somebody else between runs) — a Replace
    /// onto a single new address would then take part of the routes to the wrong
    /// place, and run() would only learn of it by watching the live diamond after the
    /// rollout.
    function test_PreflightRevertsWhenReplaceSelectorLivesElsewhere() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        // A separate, third facet — one of the "remaining" selectors
        // (getRefundableBounty) is moved onto it by a separate Replace BEFORE the
        // pre-flight check, simulating somebody else's intervening upgrade.
        ArbiterRegistryFacet strayFacet = new ArbiterRegistryFacet();
        bytes4[] memory strayMount = new bytes4[](1);
        strayMount[0] = ArbiterRegistryFacet.getRefundableBounty.selector;
        IDiamondCut.FacetCut[] memory strayCut = new IDiamondCut.FacetCut[](1);
        strayCut[0] = IDiamondCut.FacetCut(address(strayFacet), IDiamondCut.FacetCutAction.Replace, strayMount);
        IDiamondCut(address(diamond)).diamondCut(strayCut, address(0), "");

        // The list goes into a local variable BEFORE expectRevert: expectRevert
        // catches exactly the next external call, and replaceSelectors() as an inline
        // argument would itself be that "next call" (a staticcall), not checkReplaceGroup.
        bytes4[] memory sels = upgrade.replaceSelectors();
        vm.expectRevert(bytes("UpgradeArbiterChatKey: Replace selectors are split across more than one live facet address"));
        upgrade.checkReplaceGroup(sels, address(diamond));
    }

    /// What disappears if the fix is removed: the script runs against a diamond where
    /// an Add selector is already mounted by somebody (a repeated run of the same
    /// script, say, or somebody else's parallel cut) — the diamond reverts the whole
    /// diamondCut with "Diamond: selector exists" AFTER the new facet has been
    /// broadcast (the deployment happens, the cut does not), instead of a
    /// comprehensible refusal before a single unit of gas is spent.
    function test_PreflightRevertsWhenAddSelectorAlreadyMounted() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        ArbiterRegistryFacet stray = new ArbiterRegistryFacet();
        bytes4[] memory strayAdd = new bytes4[](1);
        strayAdd[0] = ArbiterRegistryFacet.setArbiterChatKey.selector;
        IDiamondCut.FacetCut[] memory strayCut = new IDiamondCut.FacetCut[](1);
        strayCut[0] = IDiamondCut.FacetCut(address(stray), IDiamondCut.FacetCutAction.Add, strayAdd);
        IDiamondCut(address(diamond)).diamondCut(strayCut, address(0), "");

        bytes4[] memory sels = upgrade.addSelectors();
        vm.expectRevert(bytes("UpgradeArbiterChatKey: an Add selector is already mounted somewhere - Add would revert"));
        upgrade.checkAddGroupUnmounted(sels, address(diamond));
    }

    /// What disappears if the fix is removed: Remove would point at a selector other
    /// than the one really standing on the old facet (somebody corrupted
    /// removeSelectors() into an unmounted signature, say) — the cut would revert
    /// whole on the live diamond only at the moment of broadcast, rather than in
    /// advance.
    function test_PreflightRevertsWhenRemoveSelectorNotMounted() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);

        bytes4[] memory bogus = new bytes4[](1);
        bogus[0] = bytes4(keccak256("thisSelectorDoesNotExistAnywhere()"));

        vm.expectRevert(bytes("UpgradeArbiterChatKey: Remove selector is not mounted anywhere"));
        upgrade.checkRemoveSelectorMounted(bogus, address(0xDEAD), address(diamond));
    }

    /// What disappears if the fix is removed: the selector being deleted is mounted
    /// (it passes the first require) but lives on a DIFFERENT address from the whole
    /// Replace group — that is, Remove aims at a facet other than the one being
    /// upgraded by this cut (somebody has already partly migrated the claim to a new
    /// address with a separate cut, say, leaving the old signature hanging elsewhere).
    /// Without this check the script would learn of it only after the fact — Remove
    /// would take the selector off somebody else's facet rather than off the one
    /// being replaced. Found by mutation: removing
    /// `require(a == expectedFacet, ...)` gave 0 red out of 11 without this test —
    /// the check existed, but nothing in the suite exercised it.
    function test_PreflightRevertsWhenRemoveSelectorLivesOnDifferentFacet() public {
        DiamondProxy diamond = _deployMinimalDiamond();

        // The Replace group is on one facet (A).
        ArbiterRegistryFacet facetA = new ArbiterRegistryFacet();
        IDiamondCut.FacetCut[] memory mountReplace = new IDiamondCut.FacetCut[](1);
        mountReplace[0] = IDiamondCut.FacetCut(address(facetA), IDiamondCut.FacetCutAction.Add, upgrade.replaceSelectors());
        IDiamondCut(address(diamond)).diamondCut(mountReplace, address(0), "");

        // The selector being deleted is on ANOTHER facet (B), not on facetA.
        ArbiterRegistryFacet facetB = new ArbiterRegistryFacet();
        IDiamondCut.FacetCut[] memory mountRemove = new IDiamondCut.FacetCut[](1);
        mountRemove[0] = IDiamondCut.FacetCut(address(facetB), IDiamondCut.FacetCutAction.Add, upgrade.removeSelectors());
        IDiamondCut(address(diamond)).diamondCut(mountRemove, address(0), "");

        bytes4[] memory removeSels = upgrade.removeSelectors();
        vm.expectRevert(bytes("UpgradeArbiterChatKey: Remove selector lives on a different facet address than the Replace group"));
        upgrade.checkRemoveSelectorMounted(removeSels, address(facetA), address(diamond));
    }

    /// The full cycle on a local diamond: deploy → mount the "old" layout →
    /// pre-flight checks (as in run(), before the broadcast) → the cut itself through
    /// buildCuts() (the same function run() calls) → post-flight checks → a
    /// getArbiterChatKeys smoke test THROUGH THE DIAMOND. The most valuable test
    /// here: it alone proves that the script's whole road — not only the selector
    /// lists — leads to a diamond that really works, rather than to one where a
    /// selector "counts as mounted but reverts with empty returndata".
    function test_FullUpgradeCycleOnLocalDiamond() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        // ── Pre-flight (as in run()) ────────────────────────────────────
        address foundOld = upgrade.checkReplaceGroup(upgrade.replaceSelectors(), address(diamond));
        assertEq(foundOld, oldFacetAddr);
        upgrade.checkRemoveSelectorMounted(upgrade.removeSelectors(), oldFacetAddr, address(diamond));
        upgrade.checkAddGroupUnmounted(upgrade.addSelectors(), address(diamond));

        uint256 before = upgrade.totalRoutedSelectors(address(diamond));

        // ── The cut itself — buildCuts(), the same function run() calls ──
        // The "facet from before the split" double: this cut was executed on
        // 10 August 2026, when getArbiterChatKeys still lived in the registry. The
        // smoke test below calls it for real, so that day is reproduced exactly
        // rather than approximately.
        LegacyPreSplitArbiterFacet newFacet = new LegacyPreSplitArbiterFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(newFacet)), address(0), "");

        // ── Post-flight (as in run()) ─────────────────────────────────
        upgrade.assertRouted(upgrade.replaceSelectors(), address(newFacet), address(diamond));
        upgrade.assertRouted(upgrade.addSelectors(), address(newFacet), address(diamond));
        upgrade.assertFacetHoldsNoSelectors(oldFacetAddr, address(diamond));
        upgrade.assertSelectorsUnrouted(upgrade.removeSelectors(), address(diamond));

        uint256 afterTotal = upgrade.totalRoutedSelectors(address(diamond));
        assertEq(
            afterTotal,
            before - upgrade.removeSelectors().length + upgrade.addSelectors().length,
            "total routed selectors did not move by exactly -Remove +Add"
        );

        // ── Functional smoke test: a real call THROUGH THE DIAMOND ──────
        (bytes32 boxKey, bytes32 signKey) = upgrade.smokeGetArbiterChatKeys(address(diamond), address(0xDEAD));
        assertEq(boxKey, bytes32(0), "smoke: getArbiterChatKeys through the diamond did not return zero boxKey");
        assertEq(signKey, bytes32(0), "smoke: getArbiterChatKeys through the diamond did not return zero signKey");

        // The same call directly through the facet interface (not only through the
        // script's helper) — it confirms that the delegation really executes the new
        // facet's code rather than merely failing to revert on an empty fallback.
        (bytes32 boxKey2, bytes32 signKey2) = ArbiterAccountabilityFacet(address(diamond)).getArbiterChatKeys(address(0xDEAD));
        assertEq(boxKey2, bytes32(0));
        assertEq(signKey2, bytes32(0));
    }

    /// Literally run() — not a manual reproduction of its steps but the method
    /// itself, with real vm.envAddress/vm.envUint/vm.startBroadcast, on a locally
    /// deployed diamond. The diamond's owner is the address derived from PRIVATE_KEY
    /// (the two-step handover of OwnershipFacet), exactly as diamondCut requires on
    /// the live chain. This is the only test that proves by measurement that the
    /// smoke check INSIDE run() (after the broadcast,
    /// `require(boxKey == 0 && signKey == 0, ...)`) really is in place — the other
    /// tests call it through smokeGetArbiterChatKeys() separately but not through
    /// run() itself, and would not catch somebody deleting that particular line from
    /// run() rather than from the extracted helper.
    ///
    /// The diamond is seeded non-empty BEFORE the cut — a registered arbiter, a
    /// non-empty vaultBalance and (by a raw write, see _setChatKeyRaw) filled
    /// arbiterBoxKey/arbiterSignKey. Without that, the storage-continuity check
    /// INSIDE run() would compare zeroes with zeroes and would pass even if it were
    /// completely broken. After run() it is checked that arbiterCount/vaultBalance
    /// survived the cut through snapshotArbiterStorage(), and that the raw key bytes
    /// written BEFORE getArbiterChatKeys existed at all are read back THROUGH IT now
    /// that it is mounted.
    function test_RunEndToEndOnLocalDiamond() public {
        uint256 pk = 0xA11CE;
        address ownerAddr = vm.addr(pk);
        address seededArbiter = address(0xA12BE12);

        DiamondProxy diamond = _deployMinimalDiamond(); // owner = address(this) at first
        address oldFacetAddr = _mountOldFacet(diamond);  // as address(this) too
        _seedPreCutArbiterState(diamond, seededArbiter); // non-empty storage BEFORE the cut

        UpgradeArbiterChatKey.StorageSnapshot memory before = upgrade.snapshotArbiterStorage(address(diamond));
        assertEq(before.arbiterCount, 1, "the seed did not add an arbiter, so the comparison below would be zeroes against zeroes");
        assertEq(before.vaultBalance, 777_000_000, "the seed did not raise vaultBalance");

        // Hand ownership of the diamond to the PRIVATE_KEY address — run() calls
        // diamondCut, and that only goes through for the owner.
        OwnershipFacet(address(diamond)).transferOwnership(ownerAddr);
        vm.prank(ownerAddr);
        OwnershipFacet(address(diamond)).acceptOwnership();
        assertEq(OwnershipFacet(address(diamond)).owner(), ownerAddr, "ownership transfer did not take");

        // ⚠️ A RACE THROUGH THE PROCESS-GLOBAL vm.setEnv. `vm.setEnv` writes into the
        // PROCESS environment, while forge's suites run in parallel. Three cut
        // benches (ArbiterAccountabilityUpgrade, PresentationRecordUpgrade,
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
        // address through the environment at all, and that is recorded separately as
        // an open item. This line turns a future flake into a DETERMINISTIC red with a
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

        uint256 before_ = upgrade.totalRoutedSelectors(address(diamond));

        upgrade.run(); // ← the method itself, not a retelling of it (this proves the continuity require INSIDE run())

        // run() checks everything inside itself (otherwise it would already have
        // reverted); here that is duplicated from the outside, showing that the
        // diamond really did move as promised.
        upgrade.assertFacetHoldsNoSelectors(oldFacetAddr, address(diamond));
        upgrade.assertSelectorsUnrouted(upgrade.removeSelectors(), address(diamond));

        uint256 afterTotal = upgrade.totalRoutedSelectors(address(diamond));
        assertEq(afterTotal, before_ - upgrade.removeSelectors().length + upgrade.addSelectors().length);

        (bytes32 boxKey, bytes32 signKey) = ArbiterAccountabilityFacet(address(diamond)).getArbiterChatKeys(address(0xDEAD));
        assertEq(boxKey, bytes32(0));
        assertEq(signKey, bytes32(0));

        // The non-empty state seeded BEFORE the cut survived the replacement of the
        // facet address — not a comparison of zeroes with zeroes.
        UpgradeArbiterChatKey.StorageSnapshot memory afterCut = upgrade.snapshotArbiterStorage(address(diamond));
        assertEq(afterCut.arbiterCount, before.arbiterCount, "arbiterCount did not survive the cut");
        assertEq(afterCut.vaultBalance, before.vaultBalance, "vaultBalance did not survive the cut");

        (bytes32 seededBox, bytes32 seededSign) = ArbiterAccountabilityFacet(address(diamond)).getArbiterChatKeys(seededArbiter);
        assertEq(seededBox, SEED_BOX_KEY, "arbiterBoxKey written BEFORE the cut did not survive the facet replacement");
        assertEq(seededSign, SEED_SIGN_KEY, "arbiterSignKey written BEFORE the cut did not survive the facet replacement");
    }

    /// The post-flight check "the old address is empty" catches an under-mounted
    /// Replace: had buildCuts() forgotten one of the 53 selectors (the same class of
    /// mutation as test_ReplaceAndAddCoverWholeFacet, but here by the fact of routing
    /// on a live diamond rather than by the lists), the old facet would still hold at
    /// least one selector, and assertFacetHoldsNoSelectors must notice.
    function test_PostflightRevertsWhenOldFacetStillHoldsASelector() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        // A cut that moves every selector EXCEPT one — a deliberately incomplete
        // Replace, assembled by hand (not through buildCuts()) in order to exercise
        // the post-flight helper in isolation.
        bytes4[] memory full = upgrade.replaceSelectors();
        bytes4[] memory incomplete = new bytes4[](full.length - 1);
        for (uint256 i = 0; i < incomplete.length; i++) incomplete[i] = full[i];

        ArbiterRegistryFacet newFacet = new ArbiterRegistryFacet();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(address(newFacet), IDiamondCut.FacetCutAction.Replace, incomplete);
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        vm.expectRevert(bytes("UpgradeArbiterChatKey: old facet address still holds selectors after the cut"));
        upgrade.assertFacetHoldsNoSelectors(oldFacetAddr, address(diamond));
    }

    /// What disappears if the fix is removed: the post-flight check can be called
    /// with an address nothing actually landed on (run() swapped the variables for
    /// the old and new facet addresses, say), and it would quietly agree. Found by
    /// mutation: removing the require in assertRouted gave 0 red out of 12 without
    /// this test — the only road by which assertRouted was exercised until now
    /// (test_FullUpgradeCycleOnLocalDiamond) called it on an HONEST state, where the
    /// require is true anyway, so the absence of the check on a LYING state was
    /// indistinguishable from its presence.
    function test_PostflightRevertsWhenSelectorNotRoutedToExpectedFacet() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        address oldFacetAddr = _mountOldFacet(diamond);

        ArbiterRegistryFacet newFacet = new ArbiterRegistryFacet();
        IDiamondCut(address(diamond)).diamondCut(upgrade.buildCuts(address(newFacet)), address(0), "");

        // It really landed on newFacet, but the check is made against the OLD (now
        // empty) address — it must revert.
        bytes4[] memory sels = upgrade.replaceSelectors();
        vm.expectRevert(bytes("UpgradeArbiterChatKey: a selector did not land on the new facet"));
        upgrade.assertRouted(sels, oldFacetAddr, address(diamond));
    }

    /// What disappears if the fix is removed: the post-flight check can be called
    /// BEFORE Remove has actually taken the selector off (if run() got the order
    /// wrong or skipped that action in the cut), and it would quietly agree, leaving
    /// the second road to a claim mounted. Found by a mutation of the same shape as
    /// in the previous test: until this test, assertSelectorsUnrouted was exercised
    /// only on an honest post-cut state.
    function test_PostflightRevertsWhenRemovedSelectorStillRoutesSomewhere() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond); // the old entrance is STILL mounted, Remove was not executed

        bytes4[] memory removeSels = upgrade.removeSelectors();
        vm.expectRevert(bytes("UpgradeArbiterChatKey: a removed selector still routes somewhere"));
        upgrade.assertSelectorsUnrouted(removeSels, address(diamond));
    }

    // ════════════════════════════════════════════════════════════════════
    // Continuity of the arbiter namespace's storage across the cut — not only
    // selector routing.
    // ════════════════════════════════════════════════════════════════════

    /// An honest state: an identical before/after snapshot does not revert.
    function test_StorageContinuity_PassesOnUnchangedSnapshot() public view {
        UpgradeArbiterChatKey.StorageSnapshot memory s =
            UpgradeArbiterChatKey.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 5});
        upgrade.assertStorageContinuity(s, s); // nothing reverted — the point of the test
    }

    /// What disappears if the fix is removed: the upgrade script drives silently past
    /// a shift in the arbiter namespace's layout — exactly the class that in July
    /// 2026 brought getOpenJobs() down with Panic(0x22) on live JobBoard storage,
    /// AFTER the rollout rather than before.
    function test_StorageContinuity_RevertsWhenArbiterCountChanged() public {
        UpgradeArbiterChatKey.StorageSnapshot memory b =
            UpgradeArbiterChatKey.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 5});
        UpgradeArbiterChatKey.StorageSnapshot memory a =
            UpgradeArbiterChatKey.StorageSnapshot({arbiterCount: 4, vaultBalance: 100, arbiterFloor: 5});
        vm.expectRevert(bytes("post: getArbiters().length changed across the cut - storage layout may have shifted"));
        upgrade.assertStorageContinuity(b, a);
    }

    function test_StorageContinuity_RevertsWhenVaultBalanceChanged() public {
        UpgradeArbiterChatKey.StorageSnapshot memory b =
            UpgradeArbiterChatKey.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 5});
        UpgradeArbiterChatKey.StorageSnapshot memory a =
            UpgradeArbiterChatKey.StorageSnapshot({arbiterCount: 3, vaultBalance: 101, arbiterFloor: 5});
        vm.expectRevert(bytes("post: getVaultBalance() changed across the cut - storage layout may have shifted"));
        upgrade.assertStorageContinuity(b, a);
    }

    function test_StorageContinuity_RevertsWhenArbiterFloorChanged() public {
        UpgradeArbiterChatKey.StorageSnapshot memory b =
            UpgradeArbiterChatKey.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 5});
        UpgradeArbiterChatKey.StorageSnapshot memory a =
            UpgradeArbiterChatKey.StorageSnapshot({arbiterCount: 3, vaultBalance: 100, arbiterFloor: 6});
        vm.expectRevert(bytes("post: getArbiterFloor() changed across the cut - storage layout may have shifted"));
        upgrade.assertStorageContinuity(b, a);
    }

    // ════════════════════════════════════════════════════════════════════
    // The warning about arbiters with open claims and no key — loud, not a require.
    // ════════════════════════════════════════════════════════════════════

    /// An arbiter with an open dispute (openClaimCount > 0) must land in the list.
    function test_FindArbitersWithOpenClaimsMissingKeys_FlagsArbiterWithOpenClaim() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);
        ArbiterRegistryFacet f = ArbiterRegistryFacet(address(diamond));

        address arb = address(0xAB1);
        f.addArbiter(arb);
        _setOpenClaimCount(diamond, arb, 1);

        address[] memory flagged = upgrade.findArbitersWithOpenClaimsMissingKeys(address(diamond));
        assertEq(flagged.length, 1, "an arbiter with an open dispute must land in the warning");
        assertEq(flagged[0], arb);
    }

    /// What disappears if the fix is removed: the script's pre-flight stops warning
    /// about arbiters whose old claims (taken before the upgrade, keyless by
    /// construction) will give getArbiterChatKeys == (0, 0) after the cut — a party
    /// silently hears "there is nobody to present to" instead of "the arbiter needs to
    /// call setArbiterChatKey".
    function test_FindArbitersWithOpenClaimsMissingKeys_SkipsArbiterWithoutOpenClaim() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);
        ArbiterRegistryFacet f = ArbiterRegistryFacet(address(diamond));

        address arb = address(0xAB2);
        f.addArbiter(arb); // registered, but openClaimCount == 0

        address[] memory flagged = upgrade.findArbitersWithOpenClaimsMissingKeys(address(diamond));
        assertEq(flagged.length, 0, "with no open dispute there is nothing to warn about");
    }

    /// An arbiter with no open dispute does not land in the list even if they are the
    /// only registered one, while another (with an open dispute) does: the list
    /// filters per arbiter rather than by "is there anybody at all".
    function test_FindArbitersWithOpenClaimsMissingKeys_MixOfFlaggedAndNot() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond);
        ArbiterRegistryFacet f = ArbiterRegistryFacet(address(diamond));

        address quiet = address(0xAB3);
        address busy  = address(0xAB4);
        f.addArbiter(quiet);
        f.addArbiter(busy);
        _setOpenClaimCount(diamond, busy, 2);

        address[] memory flagged = upgrade.findArbitersWithOpenClaimsMissingKeys(address(diamond));
        assertEq(flagged.length, 1);
        assertEq(flagged[0], busy);
    }

    /// findArbitersWithOpenClaimsMissingKeys is called BEFORE the broadcast in run()
    /// — that is, BEFORE getArbiterChatKeys is mounted on the diamond at all (it is
    /// one of the three Add selectors of the same cut). A lock against the
    /// regression: had the function read getArbiterChatKeys directly (as the first
    /// version of this fix did), it would have reverted "Diamond: Function does not
    /// exist" on EVERY pre-flight call on the live chain — the warning would have
    /// taken the whole script down instead of merely printing.
    function test_FindArbitersWithOpenClaimsMissingKeys_WorksBeforeAddSelectorsAreMounted() public {
        DiamondProxy diamond = _deployMinimalDiamond();
        _mountOldFacet(diamond); // ONLY the old layout — getArbiterChatKeys is NOT mounted
        ArbiterRegistryFacet f = ArbiterRegistryFacet(address(diamond));

        address arb = address(0xAB5);
        f.addArbiter(arb);
        _setOpenClaimCount(diamond, arb, 1);

        // First the premise is proved: getArbiterChatKeys really is not mounted on
        // this diamond before the cut.
        vm.expectRevert();
        ArbiterAccountabilityFacet(address(diamond)).getArbiterChatKeys(arb);

        // And the warning meanwhile runs without a single revert.
        address[] memory flagged = upgrade.findArbitersWithOpenClaimsMissingKeys(address(diamond));
        assertEq(flagged.length, 1);
        assertEq(flagged[0], arb);
    }
}
