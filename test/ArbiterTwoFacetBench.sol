// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
// A LIGHT BENCH CARRYING BOTH ARBITER FACETS
//
// WHY IT EXISTS. The previous light bench deployed ONE facet
// (`facet = new ArbiterRegistryFacet()`) and called it directly. While every
// function a test needed lived in one contract, that worked and was cheap.
//
// Moving fourteen READERS into ArbiterAccountabilityFacet breaks that device —
// silently and dangerously. Both facets read ONE namespace
// (ArbiterRegistryStorage, the same POSITION), but a namespace is an OFFSET,
// not an address: two separate `new`s give two DIFFERENT contracts with two
// DIFFERENT storages at one and the same offset. A test that writes through
// `new ArbiterRegistryFacet()` and reads through
// `new ArbiterAccountabilityFacet()` would read a clean zero and call it an
// answer.
//
// WHAT THIS BENCH DOES. It gives ONE address behind which the code of BOTH
// facets stands — which is exactly what a diamond is in production. Both
// returned handles point at THAT SAME address, so:
//
//   • `vm.store(address(reg), ...)` and `vm.load(address(acc), ...)` hit one
//     storage — every existing line that seeds a slot keeps working without a
//     single edit;
//   • `vm.expectEmit(..., address(reg))` still matches: events from a delegated
//     call carry the proxy's address;
//   • `msg.sender` inside a facet is still the test contract — delegatecall does
//     not change it, and `vm.prank` works as before.
//
// There is exactly one difference from the old bench, and it favours the test:
// `address(this)` inside a facet is now the proxy's address rather than a
// standalone facet's — the same address as in production, so the money (bond,
// vault) sits where the neighbouring facet looks for it.
//
// The selector lists are taken from DeployFull rather than rewritten here: a
// second hand-written list would drift away from the production one silently,
// and the bench would start proving something about a layout that does not
// exist.
// ============================================================

import {Vm} from "forge-std/Vm.sol";
import {DeployFull} from "../script/DeployFull.s.sol";
import {LegacyPreSplitArbiterFacet} from "./legacy/LegacyPreSplitArbiterFacet.sol";
import {ArbiterRegistryFacet, ArbiterRegistryStorage} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {
    DiamondProxy,
    DiamondCutFacet,
    DiamondLoupeFacet,
    OwnershipFacet,
    IDiamondCut,
    IDiamondLoupe,
    IERC165
} from "../src/DiamondProxy.sol";

abstract contract ArbiterTwoFacetBench {
    /// The base of FactoryStorage, and `usdc` is its FIRST field (slot +0).
    /// Held against the live layout by test/StorageLayout.t.sol.
    bytes32 internal constant BENCH_FACTORY_BASE =
        0x6e1a7c9e564b098cf0d979de1ae0cacf8bfb22a7e8f2c8f4c244a2031b744700;

    /// Puts a token under the bench that says yes to everything.
    ///
    /// ⚠️ WHY A LIGHT BENCH NEEDS A TOKEN AT ALL SINCE 22 SEPTEMBER 2026.
    /// `claimDispute` now takes a bond for the case, out of `FactoryStorage.usdc`.
    /// On a bench that never called `initFactory` that address is zero, and a
    /// high-level call into a codeless address reverts in this frame — so every
    /// scene about claiming would fail with a bare `EvmError: Revert` that says
    /// nothing about what it was measuring. The token below is deliberately
    /// permissive: these rigs are about the anchor, the key and the record, not
    /// about who can afford a bond, and a rig that had to mint and approve in
    /// every scene would be measuring the wallet instead.
    function _seedBenchUsdc(address proxy) internal returns (address token) {
        token = address(new BenchAlwaysYesUSDC());
        Vm(address(uint160(uint256(keccak256("hevm cheat code"))))).store(
            proxy, BENCH_FACTORY_BASE, bytes32(uint256(uint160(token)))
        );
    }

    /// Deploys a proxy with both arbiter facets and returns two handles TO ONE
    /// AND THE SAME ADDRESS. The caller (the test contract) becomes the owner,
    /// as it was on the old bench after a `vm.store` into the owner slot.
    /// ⚠️ THREE handles since 16 September 2026, for the same reason there were
    /// two: the money and the plain reads moved into ArbiterVaultFacet, and a
    /// namespace is an OFFSET, not an address. A separate `new ArbiterVaultFacet()`
    /// would answer out of its own empty storage and call the zero an answer.
    /// All three returned handles point at the proxy.
    function _deployArbiterBench()
        internal
        returns (ArbiterRegistryFacet reg, ArbiterAccountabilityFacet acc, ArbiterVaultFacet vault)
    {
        DeployFull deployFull = new DeployFull();

        DiamondCutFacet cutFacet     = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownFacet      = new OwnershipFacet();

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

        IDiamondCut.FacetCut[] memory initCuts = new IDiamondCut.FacetCut[](3);
        initCuts[0] = IDiamondCut.FacetCut(address(cutFacet),   IDiamondCut.FacetCutAction.Add, cutSels);
        initCuts[1] = IDiamondCut.FacetCut(address(loupeFacet), IDiamondCut.FacetCutAction.Add, loupeSels);
        initCuts[2] = IDiamondCut.FacetCut(address(ownFacet),   IDiamondCut.FacetCutAction.Add, ownSels);

        DiamondProxy diamond = new DiamondProxy(address(this), initCuts, address(0), "");

        IDiamondCut.FacetCut[] memory arbCuts = new IDiamondCut.FacetCut[](3);
        arbCuts[0] = IDiamondCut.FacetCut(
            address(new ArbiterRegistryFacet()),
            IDiamondCut.FacetCutAction.Add,
            deployFull.arbiterRegistryFacetSelectors()
        );
        arbCuts[1] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()),
            IDiamondCut.FacetCutAction.Add,
            deployFull.arbiterAccountabilityFacetSelectors()
        );
        arbCuts[2] = IDiamondCut.FacetCut(
            address(new ArbiterVaultFacet()),
            IDiamondCut.FacetCutAction.Add,
            deployFull.arbiterVaultFacetSelectors()
        );
        IDiamondCut(address(diamond)).diamondCut(arbCuts, address(0), "");

        reg   = ArbiterRegistryFacet(address(diamond));
        acc   = ArbiterAccountabilityFacet(address(diamond));
        vault = ArbiterVaultFacet(address(diamond));

        // Since 22 September 2026 `claimDispute` takes a bond for the case out
        // of `FactoryStorage.usdc`, and this bench never calls `initFactory` —
        // so without a token under it every scene about claiming would die on a
        // high-level call into address zero. See `_seedBenchUsdc`.
        _seedBenchUsdc(address(diamond));
    }

    /// Plays out, on a bench of a HISTORICAL cut, what the next cut on chain will
    /// do: it moves the relocated readers over to ArbiterAccountabilityFacet.
    ///
    /// WHY THIS IS NEEDED. The cuts that were executed (10 and 15 August 2026)
    /// deploy ONE `new ArbiterRegistryFacet()` and mount everything on it. They
    /// cannot know about the later split, and they must not be rewritten — they
    /// are the record of what went on chain. But today's ArbiterRegistryFacet no
    /// longer implements the fourteen readers, so right after such a cut they are
    /// routed to code that does not answer them.
    ///
    /// ⚠️ This is NOT a crutch in the bench, it is a faithful picture of the
    /// chain: Base Sepolia will be in exactly this state between the cut of
    /// 15 August and the cut that moves the readers. A test calling those readers
    /// after the historical cut has to play the move out first — otherwise it is
    /// checking a state the next transaction is meant to repair.
    ///
    /// ONLY those accountability-facet selectors that are actually mounted on this
    /// bench are moved — the list comes from DeployFull rather than being
    /// rewritten by hand, so it cannot drift away from the production layout.
    function _applyTask45MoveAfterLegacyCut(DiamondProxy diamond) internal {
        bytes4[] memory candidates = (new DeployFull()).arbiterAccountabilityFacetSelectors();

        uint256 n;
        bool[] memory mounted = new bool[](candidates.length);
        for (uint256 i = 0; i < candidates.length; i++) {
            if (IDiamondLoupe(address(diamond)).facetAddress(candidates[i]) != address(0)) {
                mounted[i] = true;
                n++;
            }
        }
        if (n == 0) return;

        bytes4[] memory sels = new bytes4[](n);
        uint256 k;
        for (uint256 i = 0; i < candidates.length; i++) {
            if (mounted[i]) sels[k++] = candidates[i];
        }

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()),
            IDiamondCut.FacetCutAction.Replace,
            sels
        );
        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");
    }
}

// ════════════════════════════════════════════════════════════════════════
// THE PRE-SPLIT FACET DOUBLE HAS MOVED
//
// `contract LegacyPreSplitArbiterFacet is ArbiterRegistryFacet` used to stand
// here, appending the fourteen readers that were later moved into the
// accountability facet. It INHERITED today's code and followed every edit to
// it while being declared as the layout of the CHAIN — and on 16 August it
// crossed EIP-170 (24 646 → 24 722 against a limit of 24 576), taking
// `forge build --sizes` down with exit code 1.
//
// The double is now a frozen snapshot of the shipped source:
// `test/legacy/LegacyPreSplitArbiterFacet.sol` (21 227 bytes, 3 349 to spare).
// The import at the top of this file re-exports it so that the cut benches need
// change nothing on their side.
//
// The re-export is deliberately left here rather than replaced by a direct
// import in the two benches: where the double is declared is how it gets found,
// and moving that twice would create two places to look.
// ════════════════════════════════════════════════════════════════════════

/// A token that always says yes: it is the bench's stand-in for USDC, used only
/// where the scene is not about money. It keeps balances so that a test CAN
/// assert on them, and it never refuses.
contract BenchAlwaysYesUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] >= amount) balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] >= amount) balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
