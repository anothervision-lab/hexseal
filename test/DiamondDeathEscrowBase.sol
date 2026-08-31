// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  DIAMOND-DEATH ESCROW LOCK
// ============================================================
//
// The promise under test: "money in escrow is safe". Every deal is an
// EIP-1167 clone of Agreement that holds the USDC itself; the diamond is
// only used as a registry / reputation / arbitration sidecar. If that
// promise is true, the money must leave the clone even when the diamond
// stops answering.
//
// HISTORY. On 2026-08-22 this file was written to MEASURE the promise, and
// it found the promise false for disputed deals: triggerArbiterTimeout, the
// only exit from DISPUTED, stood behind a bare
// `IArbiterRegistryFacet(diamond).hasSubmittedVerdict(...)`. A silent diamond
// meant a stranded pot, for ever, with no rescue function anywhere. The same
// day the guard was rewritten (Agreement._verdictInFlight / _diamondHasCode)
// and this file was turned from a description of the hole into the lock on
// it: every row that used to assert "money stuck" now asserts "money out".
//
// On 2026-08-23 the same file grew a FOURTH failure mode, which is not a kill
// at all: a facet that answers by EATING GAS. try/catch survives a revert but
// cannot give back gas the callee already burned, so a single such facet used
// to inflate the cost of closing a deal 71-fold. Every diamond call Agreement
// makes now carries a measured {gas: ...} cap; the locks on that live in
// test/DiamondDeathGasCaps.t.sol, which shares this fixture.
//
// The diamond stops answering in three DIFFERENT ways, and they are not
// interchangeable:
//
//   A. SELECTORS_REMOVED — a bad diamondCut removed a selector Agreement
//      calls. The proxy fallback hits `require(facet != address(0))` and
//      reverts. Real: a Replace/Add mix-up already broke whole cuts here.
//   B. FACET_REVERTS     — the selector is mounted but the facet behind it
//      reverts on every call. Real: a broken upgrade.
//   C. NO_CODE           — nothing at the diamond address at all. This is
//      NOT the same as A or B: solc emits an `extcodesize` guard for calls
//      that expect no return data, and that guard reverts in the CALLER's
//      own frame — outside the try/catch region. See
//      testTryCatchDoesNotCatchExtcodesizeGuard below. try/catch therefore
//      cannot cover this mode at all, which is why Agreement now checks
//      `diamond.code.length` itself before every tolerated diamond call.
//
// Method notes (project rule "the expected value must not be derived from
// the thing under test"):
//
//   * Expected payouts are hand-written literals computed from DEAL, the
//     deal size this test picks. They are never read back out of Agreement.
//   * "Money out" is measured as a USDC balance delta on the mock token,
//     which is a contract the diamond does not touch.
//   * Every kill is proved to have actually killed something: the ALIVE
//     baseline asserts the registry status really did move to COMPLETED and
//     that RegistrySyncFailed did NOT fire. Without that baseline a removed
//     selector could be a no-op and the whole suite would be an empty
//     mutation.

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/Agreement.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ReputationFacet.sol";

// ---------- MOCK USDC ----------

contract MockUSDCDeath {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        require(balanceOf[from] >= amount, "balance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ---------- FAILURE-MODE FACETS ----------

/// Mode B: mounted, answers nothing. Reverts on every selector routed here.
contract AlwaysRevertFacet {
    error FacetIsDead();
    fallback() external payable { revert FacetIsDead(); }
}

/// The gas trap: try/catch survives a revert but not a callee that eats the
/// gas. EIP-150 leaves the caller 1/64 of what it had; two such calls in a
/// row (Agreement._complete makes exactly two) leave 1/4096.
contract GasBurnerFacet {
    fallback() external payable {
        uint256 i = 1;
        // Unbounded SSTORE loop: guaranteed to consume whatever it is given
        // and to be immune to the optimizer (real state writes).
        while (true) {
            assembly { sstore(i, i) }
            unchecked { i++; }
        }
    }
}

// ---------- EXTCODESIZE PROBE ----------
//
// Deliberately standalone and minimal. It reproduces the two call shapes
// Agreement uses, so the conclusion about extcodesize does not depend on
// reading Agreement's own bytecode.

interface IProbeNoReturn { function ping(address a) external; }
interface IProbeWithReturn { function ask(address a) external view returns (bool); }

contract ExtcodesizeProbe {
    address public target;
    constructor(address t) { target = t; }

    /// Same shape as Agreement._updateRegistry / notifyExecutorFault:
    /// external call inside try/catch, NO return data expected.
    function protectedNoReturn() external returns (bool caught) {
        try IProbeNoReturn(target).ping(address(this)) { return false; } catch { return true; }
    }

    /// The same shape Agreement uses: a bare call with return data expected.
    function bareWithReturn() external view returns (bool) {
        return IProbeWithReturn(target).ask(address(this));
    }

    /// Same shape as Agreement.setArbiter: low-level staticcall + abi.decode.
    function lowLevelStatic() external view returns (bool ok, uint256 len) {
        bytes memory data;
        (ok, data) = target.staticcall(
            abi.encodeWithSignature("isRegisteredArbiter(address)", address(this))
        );
        len = data.length;
    }
}

// ---------- VERDICT-VIEW COST PROBE ----------
//
// Measures what one `hasSubmittedVerdict` read through the diamond actually
// costs, from inside a contract frame, the way Agreement makes it. Standalone
// so the number does not come out of Agreement's own code.

contract VerdictViewProbe {
    address public diamond;
    constructor(address d) { diamond = d; }

    function measure(address subject) external view returns (uint256 used, bool ok, uint256 word) {
        bytes memory cd = abi.encodeWithSignature("hasSubmittedVerdict(address)", subject);
        address to = diamond;
        bytes memory ret;
        uint256 before = gasleft();
        (ok, ret) = to.staticcall(cd);
        used = before - gasleft();
        if (ret.length >= 32) word = abi.decode(ret, (uint256));
    }
}

// ============================================================
//  SHARED FIXTURE
// ============================================================
//
// Split out of DiamondDeathEscrow.t.sol on 2026-08-23: the gas-cap work
// (sections 14-17, now test/DiamondDeathGasCaps.t.sol) roughly doubled the
// file and solc stopped being able to assemble one contract that big
// ("Tag too large for reserved space"). The fixture is identical; only the
// tests moved.

abstract contract DiamondDeathEscrowBase is Test {
    enum Kill { ALIVE, SELECTORS_REMOVED, FACET_REVERTS, NO_CODE }

    DiamondProxy  diamond;
    MockUSDCDeath usdc;

    address owner;
    address client;
    address executor;
    address arbiterAddr;
    address feeRecipient;
    address stranger;

    /// Deal size and every expected payout below are literals fixed by hand.
    /// Nothing here is read back out of Agreement.
    uint256 constant DEAL       = 1_000_000_000;  // 1000 USDC (6 decimals)
    uint256 constant EXTRA      =   200_000_000;  // 200 USDC
    uint256 constant DEAL_HALF  =   500_000_000;  // DEAL / 2
    uint256 constant CLIENT_BAG = 1_000_000_000_000;

    // Windows, restated as literals so the test does not import its
    // expectations from the contract it is measuring.
    uint256 constant ACTIVATION_WINDOW   = 2 days;
    uint256 constant AUTO_APPROVE_WINDOW = 2 days;
    uint256 constant DISPUTE_WINDOW      = 4 days;
    uint256 constant DEADLINE_GRACE      = 1 days;
    uint256 constant DEADLINE_DAYS       = 7;

    // ============================================================
    //  SETUP  (full real diamond, shape copied from DisputeSettlement.t.sol)
    // ============================================================

    function setUp() public {
        owner        = address(this);
        client       = address(0x1);
        executor     = address(0x2);
        arbiterAddr  = address(0x3);
        feeRecipient = address(0x4);
        stranger     = address(0x5);

        usdc = new MockUSDCDeath();
        usdc.mint(client, CLIENT_BAG);

        RegistryFacet        registryFacet        = new RegistryFacet();
        FactoryFacet         factoryFacet         = new FactoryFacet();
        DiamondCutFacet      diamondCutFacet      = new DiamondCutFacet();
        DiamondLoupeFacet    diamondLoupeFacet    = new DiamondLoupeFacet();
        OwnershipFacet       ownershipFacet       = new OwnershipFacet();
        ArbiterRegistryFacet arbiterRegistryFacet = new ArbiterRegistryFacet();
        ReputationFacet      reputationFacet      = new ReputationFacet();

        bytes4[] memory regSels = new bytes4[](13);
        regSels[0]  = RegistryFacet.initRegistry.selector;
        regSels[1]  = RegistryFacet.register.selector;
        regSels[2]  = RegistryFacet.updateStatus.selector;
        regSels[3]  = RegistryFacet.setAuthorizedFactory.selector;
        regSels[4]  = RegistryFacet.hasActivePair.selector;
        regSels[5]  = RegistryFacet.getActivePair.selector;
        regSels[6]  = RegistryFacet.getRecord.selector;
        regSels[7]  = RegistryFacet.getByClient.selector;
        regSels[8]  = RegistryFacet.getByExecutor.selector;
        regSels[9]  = RegistryFacet.getActive.selector;
        regSels[10] = RegistryFacet.totalAgreements.selector;
        regSels[11] = RegistryFacet.authorizedFactory.selector;
        regSels[12] = RegistryFacet.notifyWorkHandedIn.selector;

        bytes4[] memory facSels = new bytes4[](14);
        facSels[0]  = FactoryFacet.initFactory.selector;
        facSels[1]  = FactoryFacet.deployAgreement.selector;
        facSels[2]  = FactoryFacet.setRegionFee.selector;
        facSels[3]  = FactoryFacet.setFeeRecipient.selector;
        facSels[4]  = FactoryFacet.setTrustedForwarder.selector;
        facSels[5]  = bytes4(0x16c38b3c);
        facSels[6]  = FactoryFacet.getRegionFee.selector;
        facSels[7]  = FactoryFacet.getAllFees.selector;
        facSels[8]  = FactoryFacet.getFeeRecipient.selector;
        facSels[9]  = FactoryFacet.getTrustedForwarder.selector;
        facSels[10] = bytes4(0xb187bd26);
        facSels[11] = FactoryFacet.getUsdc.selector;
        facSels[12] = bytes4(0x220f72fc);
        facSels[13] = FactoryFacet.getFeeBps.selector;

        bytes4[] memory arbSels = new bytes4[](42);
        arbSels[0]  = ArbiterRegistryFacet.setChiefArbiter.selector;
        arbSels[1]  = ArbiterRegistryFacet.addArbiter.selector;
        arbSels[2]  = ArbiterRegistryFacet.commitDisputeClaim.selector;
        arbSels[3]  = ArbiterRegistryFacet.claimDispute.selector;
        arbSels[4]  = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        arbSels[5]  = ArbiterRegistryFacet.clearDisputeClaim.selector;
        arbSels[6]  = ArbiterRegistryFacet.getChiefArbiter.selector;
        arbSels[7]  = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        arbSels[8]  = ArbiterRegistryFacet.getArbiters.selector;
        arbSels[9]  = ArbiterRegistryFacet.getDisputeClaimer.selector;
        arbSels[10] = ArbiterRegistryFacet.getClaimCommitment.selector;
        arbSels[11] = ArbiterRegistryFacet.activateDAO.selector;
        arbSels[12] = ArbiterRegistryFacet.applyAsArbiter.selector;
        arbSels[13] = ArbiterRegistryFacet.isDaoActive.selector;
        arbSels[14] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        arbSels[15] = ArbiterRegistryFacet.getDaoThreshold.selector;
        arbSels[16] = ArbiterRegistryFacet.submitVerdict.selector;
        arbSels[17] = ArbiterRegistryFacet.finalizeVerdict.selector;
        arbSels[18] = ArbiterRegistryFacet.overturnVerdict.selector;
        arbSels[19] = ArbiterRegistryFacet.freezeVerdict.selector;
        arbSels[20] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        arbSels[21] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        arbSels[22] = ArbiterRegistryFacet.fundVault.selector;
        arbSels[23] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        arbSels[24] = ArbiterRegistryFacet.setDAOAddress.selector;
        arbSels[25] = ArbiterRegistryFacet.getPendingVerdict.selector;
        arbSels[26] = ArbiterRegistryFacet.getVaultBalance.selector;
        arbSels[27] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        arbSels[28] = ArbiterRegistryFacet.getDAOAddress.selector;
        arbSels[29] = ArbiterRegistryFacet.clearStuckVerdict.selector;
        arbSels[30] = ArbiterRegistryFacet.creditDisputeFee.selector;
        arbSels[31] = ArbiterRegistryFacet.getTreasurySlice.selector;
        arbSels[32] = ArbiterRegistryFacet.withdrawTreasurySlice.selector;
        arbSels[33] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        arbSels[34] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        arbSels[35] = ArbiterRegistryFacet.setArbiterFloor.selector;
        arbSels[36] = ArbiterRegistryFacet.getArbiterFloor.selector;
        arbSels[37] = ArbiterRegistryFacet.quoteDisputeTopUp.selector;
        arbSels[38] = ArbiterRegistryFacet.fundDispute.selector;
        arbSels[39] = ArbiterRegistryFacet.getDisputeBounty.selector;
        arbSels[40] = ArbiterRegistryFacet.withdrawDisputeBounty.selector;
        arbSels[41] = ArbiterRegistryFacet.getRefundableBounty.selector;

        bytes4[] memory accSels = new bytes4[](3);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        accSels[1] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        accSels[2] = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;

        // autoAwardXP and notifyExecutorFault are mounted ON PURPOSE. Every
        // other suite here leaves them off, which would make "remove the
        // selector" a no-op and every measurement below meaningless.
        bytes4[] memory repSels = new bytes4[](4);
        repSels[0] = ReputationFacet.getUnresolvedDisputes.selector;
        repSels[1] = ReputationFacet.autoAwardXP.selector;
        repSels[2] = ReputationFacet.notifyExecutorFault.selector;
        repSels[3] = ReputationFacet.getXP.selector;

        bytes4[] memory cutSels = new bytes4[](1);
        cutSels[0] = DiamondCutFacet.diamondCut.selector;

        bytes4[] memory loupeSels = new bytes4[](5);
        loupeSels[0] = DiamondLoupeFacet.facets.selector;
        loupeSels[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        loupeSels[2] = DiamondLoupeFacet.facetAddresses.selector;
        loupeSels[3] = DiamondLoupeFacet.facetAddress.selector;
        loupeSels[4] = DiamondLoupeFacet.supportsInterface.selector;

        bytes4[] memory ownSels = new bytes4[](4);
        ownSels[0] = OwnershipFacet.transferOwnership.selector;
        ownSels[1] = OwnershipFacet.owner.selector;
        ownSels[2] = OwnershipFacet.acceptOwnership.selector;
        ownSels[3] = OwnershipFacet.pendingOwner.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](8);
        cut[0] = IDiamondCut.FacetCut(address(registryFacet),        IDiamondCut.FacetCutAction.Add, regSels);
        cut[1] = IDiamondCut.FacetCut(address(factoryFacet),         IDiamondCut.FacetCutAction.Add, facSels);
        cut[2] = IDiamondCut.FacetCut(address(diamondCutFacet),      IDiamondCut.FacetCutAction.Add, cutSels);
        cut[3] = IDiamondCut.FacetCut(address(diamondLoupeFacet),    IDiamondCut.FacetCutAction.Add, loupeSels);
        cut[4] = IDiamondCut.FacetCut(address(ownershipFacet),       IDiamondCut.FacetCutAction.Add, ownSels);
        cut[5] = IDiamondCut.FacetCut(address(arbiterRegistryFacet), IDiamondCut.FacetCutAction.Add, arbSels);
        cut[6] = IDiamondCut.FacetCut(address(reputationFacet),      IDiamondCut.FacetCutAction.Add, repSels);
        cut[7] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()), IDiamondCut.FacetCutAction.Add, accSels
        );

        diamond = new DiamondProxy(owner, cut, address(0), "");

        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiterAddr);
    }

    // ============================================================
    //  KILL SWITCHES
    // ============================================================

    /// Every selector Agreement calls on the diamond. Hand-collected from
    /// src/Agreement.sol lines 495, 795, 827, 849, 875, 964, 1253, 1262,
    /// 1281, 1286 — not derived from anything the test also checks.
    function _agreementCallSelectors() internal pure returns (bytes4[] memory sels) {
        sels = new bytes4[](7);
        sels[0] = bytes4(keccak256("updateStatus(address,uint8)"));
        sels[1] = bytes4(keccak256("autoAwardXP(address)"));
        sels[2] = bytes4(keccak256("notifyExecutorFault(address)"));
        sels[3] = bytes4(keccak256("notifyArbiterTimeout(address)"));
        sels[4] = bytes4(keccak256("hasSubmittedVerdict(address)"));
        sels[5] = bytes4(keccak256("creditDisputeFee(uint256)"));
        sels[6] = bytes4(keccak256("clearDisputeClaim(address)"));
    }

    function _kill(Kill mode) internal {
        if (mode == Kill.ALIVE) return;

        if (mode == Kill.NO_CODE) {
            vm.etch(address(diamond), "");
            return;
        }

        bytes4[] memory sels = _agreementCallSelectors();
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);

        if (mode == Kill.SELECTORS_REMOVED) {
            cut[0] = IDiamondCut.FacetCut({
                facetAddress:      address(0),
                action:            IDiamondCut.FacetCutAction.Remove,
                functionSelectors: sels
            });
        } else {
            cut[0] = IDiamondCut.FacetCut({
                facetAddress:      address(new AlwaysRevertFacet()),
                action:            IDiamondCut.FacetCutAction.Replace,
                functionSelectors: sels
            });
        }
        DiamondCutFacet(address(diamond)).diamondCut(cut, address(0), "");
    }

    /// Proof that the kill is not an empty mutation: after SELECTORS_REMOVED
    /// / FACET_REVERTS the selector must genuinely stop answering. NO_CODE is
    /// self-evident (address has no code) and checked separately.
    function _assertDiamondReallyDeaf(Kill mode) internal view {
        if (mode == Kill.ALIVE) {
            (bool ok, ) = address(diamond).staticcall(
                abi.encodeWithSignature("hasSubmittedVerdict(address)", address(0x1234))
            );
            assertTrue(ok, "baseline must answer, otherwise every kill below is a no-op");
            return;
        }
        if (mode == Kill.NO_CODE) {
            assertEq(address(diamond).code.length, 0, "NO_CODE must leave no code");
            return;
        }
        (bool ok2, ) = address(diamond).staticcall(
            abi.encodeWithSignature("hasSubmittedVerdict(address)", address(0x1234))
        );
        assertFalse(ok2, "kill did not actually silence the diamond");
    }

    // ============================================================
    //  DEAL BUILDERS
    // ============================================================

    function _createFundedAgreement() internal returns (Agreement) {
        vm.prank(client);
        usdc.approve(address(diamond), type(uint256).max);
        // `deployAgreement` takes the diamond and nobody else now, so this
        // fixture stands where a board stands: acceptApplicant/acceptRequest
        // reach it as `address(this).call(...)` from inside the diamond.
        vm.prank(address(diamond));
        address a = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), DEAL, DEADLINE_DAYS, "terms", 0
        );

        usdc.mint(client, DEAL);
        vm.startPrank(client);
        usdc.approve(a, DEAL);
        Agreement(a).fund();
        vm.stopPrank();
        return Agreement(a);
    }

    function _activated() internal returns (Agreement a) {
        a = _createFundedAgreement();
        vm.prank(executor);
        a.activate();
    }

    function _markedDone() internal returns (Agreement a) {
        a = _activated();
        vm.prank(executor);
        a.markDone();
    }

    function _claimByArbiter(Agreement a) internal {
        bytes32 salt       = keccak256(abi.encodePacked("death-salt", address(a), block.number));
        bytes32 commitment = keccak256(abi.encodePacked(address(a), arbiterAddr, salt));
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            address(a), salt, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    // ============================================================
    //  MEASUREMENT
    // ============================================================

    struct Snap { uint256 clientBal; uint256 executorBal; uint256 escrowBal; }

    function _snap(Agreement a) internal view returns (Snap memory s) {
        s.clientBal   = usdc.balanceOf(client);
        s.executorBal = usdc.balanceOf(executor);
        s.escrowBal   = usdc.balanceOf(address(a));
    }

    function _call(Agreement a, string memory sig) internal returns (bool ok) {
        (ok, ) = address(a).call(abi.encodeWithSignature(sig));
    }

    function _callAs(address who, Agreement a, string memory sig) internal returns (bool ok) {
        vm.prank(who);
        (ok, ) = address(a).call(abi.encodeWithSignature(sig));
    }

    /// Not `view` on purpose: vm.getRecordedLogs() drains the buffer, so it
    /// must run as a real call.
    function _registrySyncFailedFired() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == Agreement.RegistrySyncFailed.selector) {
                return true;
            }
        }
        return false;
    }

    /// Same drain-the-buffer caveat as _registrySyncFailedFired above.
    function _xpAwardFailedFired() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == Agreement.XpAwardFailed.selector) {
                return true;
            }
        }
        return false;
    }

    function _registryStatus(Agreement a) internal view returns (uint8) {
        RegistryStorage.AgreementRecord memory r =
            RegistryFacet(address(diamond)).getRecord(address(a));
        return uint8(r.status);
    }


    // ============================================================
    //  SHARED HELPERS  (used by both suites built on this fixture)
    // ============================================================

    /// Which diamond call a NotEnoughGasForDiamondCall refusal names.
    /// bytes4(0) if the revert was anything else.
    function _refusedCall(bytes memory ret) internal pure returns (bytes4 which) {
        if (ret.length < 36) return bytes4(0);
        bytes4 sel;
        assembly { sel := mload(add(ret, 0x20)) }
        if (sel != Agreement.NotEnoughGasForDiamondCall.selector) return bytes4(0);
        assembly { which := mload(add(ret, 0x24)) }
    }

    function _revertSelector(bytes memory ret) internal pure returns (bytes4 sel) {
        if (ret.length < 4) return bytes4(0);
        assembly { sel := mload(add(ret, 0x20)) }
    }

    function _facetOf(bytes4 sel) internal view returns (address) {
        return DiamondLoupeFacet(address(diamond)).facetAddress(sel);
    }

    function _mountOne(address facet, bytes4 sel, IDiamondCut.FacetCutAction action) internal {
        bytes4[] memory one = new bytes4[](1);
        one[0] = sel;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(facet, action, one);
        DiamondCutFacet(address(diamond)).diamondCut(cut, address(0), "");
    }

    /// One capped call, made the way Agreement makes it (msg.sender is the
    /// clone), with everything the call touches on the diamond side cold.
    function _measureAsAgreement(Agreement a, bytes memory cd) internal returns (uint256 used) {
        address facet = _facetOf(bytes4(cd));
        vm.cool(address(diamond));
        vm.cool(facet);
        vm.prank(address(a));
        uint256 g0 = gasleft();
        (bool ok, ) = address(diamond).call(cd);
        used = g0 - gasleft();
        assertTrue(ok, "the call must actually answer, otherwise this measures nothing");
    }

    function _assertUnderCap(string memory what, uint256 used, uint256 cap) internal {
        emit log_named_uint(what, used);
        assertLt(used, cap, "measured cost must sit under the cap");
    }

    function _callWithGas(address who, Agreement a, uint256 gasBudget, string memory sig)
        internal returns (bool ok)
    {
        vm.prank(who);
        (ok, ) = address(a).call{gas: gasBudget}(abi.encodeWithSignature(sig));
    }

    function _burnOn(bytes4 sel) internal {
        _mountOne(address(new GasBurnerFacet()), sel, IDiamondCut.FacetCutAction.Replace);
    }
}
