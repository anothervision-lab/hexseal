// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// MAKING A REHEARSAL RIG LOOK LIKE THE CHAIN ACROSS THE SEPTEMBER SPLIT
//
// ── THE PROBLEM, IN ONE PARAGRAPH ────────────────────────────────────────
// On 16 September 2026 ArbiterRegistryFacet was cut in two: twenty-eight
// selectors moved to ArbiterVaultFacet. Not one signature changed, so the
// diamond's selector SET is untouched — but this checkout now builds TWO
// contracts where Base Sepolia routes ONE. Six stands in this suite rehearse
// cuts that were ALREADY SIGNED, against a rig built out of DeployFull's own
// lists, and those cuts' pre-flights say — correctly, and this file does not
// weaken them — "every selector of a Replace group must sit on ONE facet".
//
// Two honest answers exist and this file is the first of them:
//   * make the RIG look like the chain (one host for all fifty-nine), which
//     leaves every pre-flight of every signed script untouched;
//   * teach a check that the registry facet is now a PAIR, which is right for
//     a check that has to keep working on THIS checkout rather than describe
//     a past day.
// Which one each of the six got is written at the call site, in that stand.
//
// ── WHY A DISPATCHER AND NOT A FROZEN COPY ───────────────────────────────
// The obvious double is a frozen snapshot of the pre-split source — the shape
// test/legacy/LegacyPreSplitArbiterFacet.sol already uses for the AUGUST
// split. It was not repeated here for two reasons, and the second is the one
// that decided it:
//   * four thousand lines of copied source, which has to be re-frozen by hand
//     every time the live facet gains a function before the cut is signed;
//   * a copy is a SECOND ANSWER to "what does the arbiter facet do", and the
//     whole argument of the split is that there must be exactly one. The
//     dispatcher below has no behaviour of its own at all: it forwards to the
//     two real facets, so a stand rehearsing a past cut exercises TODAY's code
//     and cannot quietly rehearse against a stale copy.
//
// ⚠️ WHAT THE DISPATCHER IS NOT. It is a test fixture and it is never
// deployed to a chain. Production keeps two facets and two rows in the routing
// table; this is one address standing in for the single row Base Sepolia had
// at every census taken before the split.
//
// ⚠️ THE SPLIT LANDED ON 17 SEPTEMBER 2026 (block 46 946 562) AND THIS FILE
// STAYS. Until then this header said every `_mountArbiterAsOneHost` call would
// become dead and come out that day. It does not: each call conforms a rig to a
// census of the PAST, read before the split, and the stands rehearse cuts
// signed against that past. Measured 18 September 2026, after the cut: without
// the call EmergencyBrakeUpgrade's setUp reverts ("the conformed rig has a
// different number of facets than the live chain had"); without one
// `_replayArbiterVaultSplit` DisputeVaultDiscountUpgrade reds
// test_PreFlightPassesAndTheCutLandsWithoutLosingTheVault. Both are about
// history and stay for as long as those stands do.
// ============================================================

import {Vm} from "forge-std/Vm.sol";
import {DeployFull} from "../script/DeployFull.s.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

/// One address that answers all fifty-nine arbiter selectors, the way Base
/// Sepolia does today, by forwarding each to whichever of the two facets
/// implements it.
///
/// ⚠️ THE FORWARD IS A DELEGATECALL, AND IT HAS TO BE. This contract is itself
/// reached by delegatecall from the diamond, so `address(this)`, `msg.sender`,
/// the calldata tail ERC-2771 reads, and — above all — the STORAGE are the
/// proxy's. A second delegatecall from here keeps every one of those. A `call`
/// would land in the facet's own empty storage and answer zero to everything,
/// which is exactly the class of bug the split had to be careful about.
contract PreSplitArbiterDispatcher {
    address public immutable registryImpl;
    address public immutable vaultImpl;

    /// ⚠️ THE ROUTING TABLE LIVES IN CODE, NOT IN STORAGE, AND THAT IS THE
    /// WHOLE TRICK. The first version of this file kept a
    /// `mapping(bytes4 => address)` and was wrong in the most instructive way
    /// available: under DELEGATECALL a mapping read does not touch THIS
    /// contract's storage at all, it touches the DIAMOND's, where the
    /// constructor never wrote anything. Every lookup answered zero and the
    /// double refused every selector. Immutables are compiled into the
    /// bytecode, so they survive the delegatecall the same way a constant does.
    ///
    /// Five words hold up to forty four-byte selectors. Four words (thirty-two)
    /// held the vault's twenty-eight at the split; the appeal economics of
    /// 17 September 2026 brought the vault to thirty-four and the table was
    /// widened by one word. A selector found here goes to the vault, anything
    /// else to the registry.
    bytes32 private immutable v0;
    bytes32 private immutable v1;
    bytes32 private immutable v2;
    bytes32 private immutable v3;
    bytes32 private immutable v4;
    uint256 private immutable vaultCount;

    constructor(address registry_, address vault_, bytes4[] memory, bytes4[] memory vaultSels) {
        registryImpl = registry_;
        vaultImpl = vault_;
        require(vaultSels.length <= 40, "PreSplitArbiterDispatcher: more than 40 moved selectors, widen the table");
        vaultCount = vaultSels.length;

        bytes32[5] memory w;
        for (uint256 i = 0; i < vaultSels.length; i++) {
            w[i / 8] |= bytes32(vaultSels[i]) >> ((i % 8) * 32);
        }
        v0 = w[0];
        v1 = w[1];
        v2 = w[2];
        v3 = w[3];
        v4 = w[4];
    }

    fallback() external payable {
        address target = _routeOf(msg.sig);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// Public so a stand can assert the double routes where it claims to,
    /// rather than taking it on trust.
    function _routeOf(bytes4 sel) public view returns (address) {
        bytes32[5] memory w = [v0, v1, v2, v3, v4];
        for (uint256 i = 0; i < vaultCount; i++) {
            if (bytes4(w[i / 8] << ((i % 8) * 32)) == sel) return vaultImpl;
        }
        return registryImpl;
    }

    receive() external payable {}
}

abstract contract ArbiterSplitRig {
    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// Both cuts below are signed by whoever the rig says its owner is, read off
    /// the diamond rather than assumed: a stand may build its rig under a prank,
    /// or name an owner that is not the test contract, and a helper that
    /// silently used `address(this)` would fail with "Diamond: not owner" in
    /// some stands and — worse — succeed for the wrong reason in others.
    function _splitRigOwner(address diamond) private view returns (address o) {
        (bool ok, bytes memory data) = diamond.staticcall(abi.encodeWithSignature("owner()"));
        require(ok && data.length == 32, "ArbiterSplitRig: the rig does not answer owner()");
        o = abi.decode(data, (address));
    }

    /// Re-points every arbiter selector a rig routes — the registry's and the
    /// vault's alike — at ONE address, so the rig has the shape Base Sepolia
    /// had before the split cut (signed 17 September 2026): thirteen facets,
    /// fifty-nine selectors on one host.
    ///
    /// Only selectors the rig ACTUALLY ROUTES are touched, and the list comes
    /// from DeployFull rather than being rewritten here: a private list would
    /// drift from the production layout in silence, and then the stand would be
    /// about a diamond that does not exist.
    ///
    /// The caller must be the diamond's owner.
    function _mountArbiterAsOneHost(address diamond) internal returns (address host) {
        DeployFull deployFull = new DeployFull();
        bytes4[] memory regSels = deployFull.arbiterRegistryFacetSelectors();
        bytes4[] memory vaultSels = deployFull.arbiterVaultFacetSelectors();

        host = address(
            new PreSplitArbiterDispatcher(
                address(new ArbiterRegistryFacet()), address(new ArbiterVaultFacet()), regSels, vaultSels
            )
        );

        bytes4[] memory mounted = _splitRigMountedOnly(diamond, _splitRigConcat(regSels, vaultSels));
        if (mounted.length == 0) return host;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(host, IDiamondCut.FacetCutAction.Replace, mounted);
        _vm.prank(_splitRigOwner(diamond));
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
    }

    /// Plays out, after a rehearsal of a PAST cut, what the September split
    /// did on the chain (block 46 946 562): the twenty-eight moved selectors go
    /// to a real ArbiterVaultFacet.
    ///
    /// WHY A STAND NEEDS THIS. A signed cut deploys ONE `new
    /// ArbiterRegistryFacet()` and mounts its whole group on it. It cannot know
    /// about a split made a month later, and it must not be rewritten — it is
    /// the record of what went on chain. But today's ArbiterRegistryFacet
    /// implements only thirty-one of those fifty-nine, so right after such a
    /// cut the other twenty-eight are routed at code that does not answer them.
    /// That is not a defect in the stand: it is a faithful picture of what the
    /// chain will look like BETWEEN the signed cut and the split, and a test
    /// that reads a moved function after the cut has to play the move out
    /// first. Same shape, and same reason, as
    /// ArbiterTwoFacetBench._applyTask45MoveAfterLegacyCut for the August split.
    function _replayArbiterVaultSplit(address diamond) internal {
        bytes4[] memory mounted = _splitRigMountedOnly(diamond, (new DeployFull()).arbiterVaultFacetSelectors());
        if (mounted.length == 0) return;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(address(new ArbiterVaultFacet()), IDiamondCut.FacetCutAction.Replace, mounted);
        _vm.prank(_splitRigOwner(diamond));
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
    }

    function _splitRigMountedOnly(address diamond, bytes4[] memory sels) private view returns (bytes4[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < sels.length; i++) {
            if (IDiamondLoupe(diamond).facetAddress(sels[i]) != address(0)) n++;
        }
        out = new bytes4[](n);
        uint256 k;
        for (uint256 i = 0; i < sels.length; i++) {
            if (IDiamondLoupe(diamond).facetAddress(sels[i]) != address(0)) out[k++] = sels[i];
        }
    }

    function _splitRigConcat(bytes4[] memory a, bytes4[] memory b) private pure returns (bytes4[] memory out) {
        out = new bytes4[](a.length + b.length);
        for (uint256 i = 0; i < a.length; i++) out[i] = a[i];
        for (uint256 i = 0; i < b.length; i++) out[a.length + i] = b[i];
    }
}
