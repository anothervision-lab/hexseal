// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterAccountabilityFacet} from "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ReputationFacet.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {HandoverReadinessSeed} from "./HandoverReadinessSeed.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Allowance exceeded");
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev A token that KNOCKS ON THE DOOR AGAIN from inside the refund transfer.
///
/// It exists to hold one ordering in place: resolveAppeal writes
/// `appealResolved`/`frozen` BEFORE it moves the deposit. That order is the only
/// thing standing between a reentrant token and a second settlement of the same
/// appeal — this facet has no nonReentrant modifier anywhere in it. Flip the two
/// writes below the transfer and the knock gets ANSWERED: the deposit is paid
/// twice and the arbiter is punished twice for one verdict.
///
/// The first two slots deliberately mirror MockUSDC's, so vm.etch can swap the
/// code under the balances the fixture has already written.
contract ReentrantUSDC {
    mapping(address => uint256) public balanceOf;                      // slot 0 — MockUSDC's
    mapping(address => mapping(address => uint256)) public allowance;  // slot 1 — MockUSDC's
    address public diamondAddr;     // slot 2 — MockUSDC leaves these free
    address public agreementAddr;   // slot 3
    bool public reentryServed;      // slot 4
    bool public fired;              // slot 4

    function arm(address d, address a) external { diamondAddr = d; agreementAddr = a; }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (diamondAddr != address(0) && !fired) {
            fired = true; // once only — this is a lock, not a recursion test
            (bool ok, ) = diamondAddr.call(
                abi.encodeWithSignature("resolveAppeal(address)", agreementAddr)
            );
            // Recorded, not asserted here: a revert inside the token would be
            // swallowed by _softTransfer and the test would read a soft refund
            // where it should read a broken lock.
            reentryServed = ok;
        }
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Allowance exceeded");
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract DiamondTest is Test, HandoverReadinessSeed {
    DiamondProxy diamond;
    MockUSDC usdc;
    
    address owner;
    address client;
    address executor;
    address arbiter;
    address feeRecipient;
    
    uint256 constant AMOUNT = 100 * 10**6;
    uint256 constant DEADLINE = 7;
    string constant TERMS_HASH = "test terms";
    bytes32 constant DISPUTE_SALT = bytes32("hexseal-test-salt");
    uint256 constant ARBITER_BOND = 50 * 10**6; // must match ArbiterRegistryFacet.ARBITER_BOND
    // erc7201:hexseal.reputation.storage — `xp` is field 0 of the struct, so the
    // per-address slot is keccak256(abi.encode(who, REP_BASE)).
    bytes32 constant REP_BASE = 0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400;

    // ArbiterRegistryStorage.POSITION, and the offset of `overturnedVerdicts`
    // inside its Data struct — 36, the field appended when overturns started
    // being counted (21 August 2026). Both are literals rather than reads: the offset is pinned by
    // test/StorageLayout.t.sol against the compiler's own view of the struct,
    // so deriving it here from the same struct would compare it with itself.
    // Used by exactly one scene, the underflow floor below, which needs a
    // history a fresh stand cannot replay.
    bytes32 constant ARB_STORAGE_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;
    uint256 constant SLOT_OVERTURNED_VERDICTS = 36;
    
    function setUp() public {
        owner = address(this);
        client = address(0x1);
        executor = address(0x2);
        arbiter = address(0x3);
        feeRecipient = address(0x4);
        
        usdc = new MockUSDC();
        usdc.mint(client, 10000 * 10**6);
        usdc.mint(feeRecipient, 10000 * 10**6);
        
        RegistryFacet registryFacet = new RegistryFacet();
        FactoryFacet factoryFacet = new FactoryFacet();
        DiamondCutFacet diamondCutFacet = new DiamondCutFacet();
        DiamondLoupeFacet diamondLoupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();
        ArbiterRegistryFacet arbiterRegistryFacet = new ArbiterRegistryFacet();
        ArbiterVaultFacet arbiterRegistryFacetVault = new ArbiterVaultFacet();
        ReputationFacet reputationFacet = new ReputationFacet();
        
        // RegistryFacet selectors
        bytes4[] memory registrySelectors = new bytes4[](14);
        registrySelectors[0] = RegistryFacet.initRegistry.selector;
        registrySelectors[1] = RegistryFacet.register.selector;
        registrySelectors[2] = RegistryFacet.updateStatus.selector;
        registrySelectors[3] = RegistryFacet.setAuthorizedFactory.selector;
        registrySelectors[4] = RegistryFacet.hasActivePair.selector;
        registrySelectors[5] = RegistryFacet.getActivePair.selector;
        registrySelectors[6] = RegistryFacet.getRecord.selector;
        registrySelectors[7] = RegistryFacet.getByClient.selector;
        registrySelectors[8] = RegistryFacet.getByExecutor.selector;
        registrySelectors[9] = RegistryFacet.getActive.selector;
        registrySelectors[10] = RegistryFacet.totalAgreements.selector;
        registrySelectors[11] = RegistryFacet.authorizedFactory.selector;
        // Appended 18 September 2026: a direct hire is an OFFER, so the
        // factory registers it through registerOffer, and the clone
        // announces the acceptance. Without both mounted this rig's
        // deployAndFund reverts with "function not found".
        registrySelectors[12] = RegistryFacet.registerOffer.selector;
        registrySelectors[13] = RegistryFacet.notifyOfferAccepted.selector;
        
        // FactoryFacet selectors
        bytes4[] memory factorySelectors = new bytes4[](13);
        factorySelectors[0] = FactoryFacet.initFactory.selector;
        factorySelectors[1] = FactoryFacet.deployAgreement.selector;
        factorySelectors[2] = FactoryFacet.setRegionFee.selector;
        factorySelectors[3] = FactoryFacet.setFeeRecipient.selector;
        factorySelectors[4] = FactoryFacet.setTrustedForwarder.selector;
        factorySelectors[5] = bytes4(0x16c38b3c);
        factorySelectors[6] = FactoryFacet.getRegionFee.selector;
        factorySelectors[7] = FactoryFacet.getAllFees.selector;
        factorySelectors[8] = FactoryFacet.getFeeRecipient.selector;
        factorySelectors[9] = FactoryFacet.getTrustedForwarder.selector;
        factorySelectors[10] = bytes4(0xb187bd26);
        factorySelectors[11] = FactoryFacet.getUsdc.selector;
        factorySelectors[12] = FactoryFacet.getFeeBps.selector;
        
        // DiamondCutFacet selectors
        bytes4[] memory cutSelectors = new bytes4[](1);
        cutSelectors[0] = DiamondCutFacet.diamondCut.selector;
        
        // DiamondLoupeFacet selectors
        bytes4[] memory loupeSelectors = new bytes4[](5);
        loupeSelectors[0] = DiamondLoupeFacet.facets.selector;
        loupeSelectors[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        loupeSelectors[2] = DiamondLoupeFacet.facetAddresses.selector;
        loupeSelectors[3] = DiamondLoupeFacet.facetAddress.selector;
        loupeSelectors[4] = DiamondLoupeFacet.supportsInterface.selector;
        
        // OwnershipFacet selectors
        bytes4[] memory ownerSelectors = new bytes4[](4);
        ownerSelectors[0] = OwnershipFacet.transferOwnership.selector;
        ownerSelectors[1] = OwnershipFacet.owner.selector;
        ownerSelectors[2] = OwnershipFacet.acceptOwnership.selector;
        ownerSelectors[3] = OwnershipFacet.pendingOwner.selector;

        // ArbiterRegistryFacet selectors
        bytes4[] memory arbiterSelectors = new bytes4[](21);
        arbiterSelectors[0] = ArbiterRegistryFacet.setChiefArbiter.selector;
        arbiterSelectors[1] = ArbiterRegistryFacet.addArbiter.selector;
        arbiterSelectors[2] = ArbiterRegistryFacet.commitDisputeClaim.selector;
        arbiterSelectors[3] = ArbiterRegistryFacet.claimDispute.selector;
        arbiterSelectors[4] = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        arbiterSelectors[5] = ArbiterRegistryFacet.clearDisputeClaim.selector;
        arbiterSelectors[6] = ArbiterRegistryFacet.activateDAO.selector;
        arbiterSelectors[7] = ArbiterRegistryFacet.applyAsArbiter.selector;
        arbiterSelectors[8] = ArbiterRegistryFacet.isDaoActive.selector;
        arbiterSelectors[9] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        arbiterSelectors[10] = ArbiterRegistryFacet.getDaoThreshold.selector;
        arbiterSelectors[11] = ArbiterRegistryFacet.submitVerdict.selector;
        arbiterSelectors[12] = ArbiterRegistryFacet.finalizeVerdict.selector;
        arbiterSelectors[13] = ArbiterRegistryFacet.setDAOAddress.selector;
        arbiterSelectors[14] = ArbiterRegistryFacet.clearStuckVerdict.selector;
        arbiterSelectors[15] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        arbiterSelectors[16] = ArbiterRegistryFacet.resignAsArbiter.selector;
        arbiterSelectors[17] = ArbiterRegistryFacet.raiseAppeal.selector;
        arbiterSelectors[18] = ArbiterRegistryFacet.voteOnAppeal.selector;
        arbiterSelectors[19] = ArbiterRegistryFacet.resolveAppeal.selector;
        arbiterSelectors[20] = ArbiterRegistryFacet.acceptDAOAddress.selector;
        bytes4[] memory arbiterSelectorsVault = new bytes4[](20);
        arbiterSelectorsVault[0] = ArbiterVaultFacet.getChiefArbiter.selector;
        arbiterSelectorsVault[1] = ArbiterVaultFacet.isRegisteredArbiter.selector;
        arbiterSelectorsVault[2] = ArbiterVaultFacet.getArbiters.selector;
        arbiterSelectorsVault[3] = ArbiterVaultFacet.getDisputeClaimer.selector;
        arbiterSelectorsVault[4] = ArbiterVaultFacet.getClaimCommitment.selector;
        arbiterSelectorsVault[5] = ArbiterVaultFacet.withdrawArbiterReward.selector;
        arbiterSelectorsVault[6] = ArbiterVaultFacet.fundVault.selector;
        arbiterSelectorsVault[7] = ArbiterVaultFacet.setRewardPerDispute.selector;
        arbiterSelectorsVault[8] = ArbiterVaultFacet.getPendingVerdict.selector;
        arbiterSelectorsVault[9] = ArbiterVaultFacet.getVaultBalance.selector;
        arbiterSelectorsVault[10] = ArbiterVaultFacet.getRewardPerDispute.selector;
        arbiterSelectorsVault[11] = ArbiterVaultFacet.getDAOAddress.selector;
        arbiterSelectorsVault[12] = ArbiterVaultFacet.hasSubmittedVerdict.selector;
        arbiterSelectorsVault[13] = ArbiterVaultFacet.getAppealVotes.selector;
        arbiterSelectorsVault[14] = ArbiterVaultFacet.hasVotedOnAppeal.selector;
        arbiterSelectorsVault[15] = ArbiterVaultFacet.getPendingDAOAddress.selector;
        arbiterSelectorsVault[16] = ArbiterVaultFacet.withdrawDisputeBounty.selector;
        arbiterSelectorsVault[17] = ArbiterVaultFacet.getRefundableBounty.selector;
        // The panel's pay and a settled appeal's ledger (17 September 2026).
        arbiterSelectorsVault[18] = ArbiterVaultFacet.getAppealShareOwed.selector;
        arbiterSelectorsVault[19] = ArbiterVaultFacet.getAppealLedger.selector;

        // These readers live in ArbiterAccountabilityFacet, so that is the
        // facet they have to be mounted on. Leaving them in the list above
        // would route them to a facet that does not implement them — the
        // call arrives and reverts.
        bytes4[] memory accSels = new bytes4[](13);
        accSels[0] = ArbiterAccountabilityFacet.getArbiterDeals.selector;
        accSels[1] = ArbiterAccountabilityFacet.getArbiterReward.selector;
        accSels[2] = ArbiterAccountabilityFacet.getArbiterMistakeStreak.selector;
        accSels[3] = ArbiterAccountabilityFacet.getArbiterBond.selector;
        accSels[4] = ArbiterAccountabilityFacet.getOpenClaimCount.selector;
        // A third judging mistake no longer removes anybody — it accuses in the
        // chain's name, and removal goes through the common door after 48 hours.
        // The demotion scenes in this file only run to the end with these four,
        // and the first of them is the button itself.
        accSels[5] = ArbiterAccountabilityFacet.executeChainRemoval.selector;
        accSels[6] = ArbiterAccountabilityFacet.getRemovalDelay.selector;
        accSels[7] = ArbiterAccountabilityFacet.hasLiveProposal.selector;
        accSels[8] = ArbiterAccountabilityFacet.isSuspended.selector;
        // Item 101 (21 August 2026): the pair "clean / overturned", and the
        // card that hands both out at once. Mounted together on purpose —
        // mounting one without the other is exactly the reading mistake the
        // item is about, and the alternation scene needs all three.
        accSels[9]  = ArbiterAccountabilityFacet.getCleanVerdicts.selector;
        accSels[10] = ArbiterAccountabilityFacet.getOverturnedVerdicts.selector;
        accSels[11] = ArbiterAccountabilityFacet.getArbiterStanding.selector;
        // The handover's second condition, mounted 20 September 2026 so that
        // `_seedHandoverLiveness` has the reader it sweeps against. Without it
        // the seeding cannot find the three counters and says so loudly.
        accSels[12] = ArbiterAccountabilityFacet.getHandoverReadiness.selector;

        // ReputationFacet selectors
        bytes4[] memory reputationSelectors = new bytes4[](9);
        reputationSelectors[0] = ReputationFacet.claimXP.selector;
        reputationSelectors[1] = ReputationFacet.getXP.selector;
        reputationSelectors[2] = ReputationFacet.getUniqueActiveUsers.selector;
        reputationSelectors[3] = ReputationFacet.hasClaimed.selector;
        reputationSelectors[4] = ReputationFacet.isDealWin.selector;
        reputationSelectors[5] = ReputationFacet.autoAwardXP.selector;
        reputationSelectors[6] = ReputationFacet.notifyExecutorFault.selector;
        reputationSelectors[7] = ReputationFacet.getCleanStreak.selector;
        // 20 September 2026. The streak, the deals that bought none of it and
        // the rule behind both, in one read — mounted here because the scenes
        // about the clean streak in this file now ask the diamond for it.
        reputationSelectors[8] = ReputationFacet.getStreakStanding.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](9);
        cut[0] = IDiamondCut.FacetCut(address(registryFacet), IDiamondCut.FacetCutAction.Add, registrySelectors);
        cut[1] = IDiamondCut.FacetCut(address(factoryFacet), IDiamondCut.FacetCutAction.Add, factorySelectors);
        cut[2] = IDiamondCut.FacetCut(address(diamondCutFacet), IDiamondCut.FacetCutAction.Add, cutSelectors);
        cut[3] = IDiamondCut.FacetCut(address(diamondLoupeFacet), IDiamondCut.FacetCutAction.Add, loupeSelectors);
        cut[4] = IDiamondCut.FacetCut(address(ownershipFacet), IDiamondCut.FacetCutAction.Add, ownerSelectors);
        cut[5] = IDiamondCut.FacetCut(address(arbiterRegistryFacet), IDiamondCut.FacetCutAction.Add, arbiterSelectors);
        cut[7] = IDiamondCut.FacetCut(
            address(new ArbiterAccountabilityFacet()), IDiamondCut.FacetCutAction.Add, accSels
        );
        cut[6] = IDiamondCut.FacetCut(address(reputationFacet), IDiamondCut.FacetCutAction.Add, reputationSelectors);
        cut[8] = IDiamondCut.FacetCut(address(arbiterRegistryFacetVault), IDiamondCut.FacetCutAction.Add, arbiterSelectorsVault);

        diamond = new DiamondProxy(owner, cut, address(0), "");
        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));

        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer));
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
        _bondSeat(arbiter);
    }
    
    
    // ============ HELPERS ============

    function _claimDispute(address agreementAddr) internal {
        _claimDisputeAs(agreementAddr, arbiter);
    }

    // Parametrized version of _claimDispute for tests using a non-default arbiter address.
    // Isolated in its own function (not inlined at each call site) — inlining this sequence
    // more than once directly inside one large test function was observed to make the second
    // vm.roll(block.number + 1) not take effect, even though the same pattern works fine via
    // a helper call.
    function _claimDisputeAs(address agreementAddr, address arbiterAddr) internal {
        bytes32 commitment = keccak256(abi.encodePacked(agreementAddr, arbiterAddr, DISPUTE_SALT));
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        uint256 nextBlock = block.number + 1;
        vm.roll(nextBlock);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agreementAddr, DISPUTE_SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    /// The appeal panel, registered at most once however often this is called.
    ///
    /// ⚠️ IDEMPOTENT ON PURPOSE, and `_addAppealQuorumArbiters` is not.
    /// That one takes the same three fixed addresses (0x30/0x31/0x32) and calls
    /// `addArbiter` unconditionally, so a second call reverts. It is fine where
    /// it is -- once per test -- but `_disputeAndOverturn` below is called ONCE
    /// PER MISTAKE, up to six times in one scene, and now needs a panel every
    /// time. Hence the registration check; the purse is topped up on every call
    /// because minting and approving again is harmless and six appeals are
    /// genuinely paid for.
    function _ensureAppealPanel() internal returns (address a2, address a3, address a4) {
        a2 = address(0x30);
        a3 = address(0x31);
        a4 = address(0x32);
        if (!ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(a2)) {
            ArbiterRegistryFacet(address(diamond)).addArbiter(a2);
        }
        if (!ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(a3)) {
            ArbiterRegistryFacet(address(diamond)).addArbiter(a3);
        }
        if (!ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(a4)) {
            ArbiterRegistryFacet(address(diamond)).addArbiter(a4);
        }
        _bondSeat(a2);
        _bondSeat(a3);
        _bondSeat(a4);
    }

    // Full deploy -> fund -> activate -> dispute -> claim -> submit -> overturn cycle against a
    // single fresh counterparty pair, for arbiter-mistake-streak tests. Kept as its own
    // function (called explicitly per-mistake rather than from a `for` loop) — looping this
    // sequence directly inside one test function was observed to make later vm.roll calls not
    // take effect under this repo's via_ir compilation; calling a helper repeatedly does not
    // have that problem.
    //
    // ⚠️ THE OVERTURN IS THE PANEL'S NOW, NOT A HAND'S (9 October 2026). The last
    // line used to be `overturnVerdict(agreementAddr, false)` — one call by the
    // owner. That door is gone, and with it the ONLY other way to reach
    // `DemotionPath.OwnerOverturn`. The replacement has to be the appeal,
    // because of what `_recordArbiterMistake` does with the path: the cumulative
    // `overturnedVerdicts` counter is an ALLOW-list of `OwnerOverturn` and
    // `AppealVote`, so a TIMEOUT — which is cheaper and would have served the
    // streak perfectly — books a mistake and leaves that counter alone. One
    // scene here reads the counter and demands six
    // (test_AlternatingMistakesLeaveTheStreakAtZeroAndTheTotalAtSix), so the
    // timeout shortcut would have made it green at zero against six expected,
    // or quietly changed what the scene measures.
    //
    // The outcome is the same as the hand produced: the arbiter rules for the
    // client, the LOSING EXECUTOR appeals (`raiseAppeal` admits only the losing
    // party, by `_msgSender()`), two of three vote to overturn, and
    // `resolveAppeal` flips `clientWins` to false and books the mistake.
    function _disputeAndOverturn(address cli, address exec, address arbiterAddr) internal returns (address agreementAddr) {
        (address a2, address a3, address a4) = _ensureAppealPanel();
        require(
            arbiterAddr != a2 && arbiterAddr != a3 && arbiterAddr != a4,
            "the ruling arbiter is sitting on his own appeal panel - pick another address"
        );
        require(
            exec != a2 && exec != a3 && exec != a4 && cli != a2 && cli != a3 && cli != a4,
            "a panel seat is a party to this deal - voteOnAppeal would refuse it"
        );

        usdc.mint(cli, 1_000_000 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, exec, arbiterAddr, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(exec);
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDisputeAs(agreementAddr, arbiterAddr);

        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreementAddr, true);

        // The losing side pays for the appeal it is about to win.
        _bondSeat(exec);
        vm.prank(exec);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agreementAddr);
        // The seats open an hour after the appeal (24 September 2026).
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        _voteOverturn(agreementAddr, a2, a3, a4);
        // 2-1 is a formed panel and not a tie, so it settles without waiting
        // out the review window.
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agreementAddr);
    }

    // Fresh deploy -> fund -> activate -> dispute -> claim -> submitVerdict cycle, stopping
    // right before finalization — the starting state every appeal test needs. `clientWins`
    // is the arbiter's ruling (true = client wins, executor loses and can appeal, and vice
    // versa).
    function _disputeToVerdict(address cli, address exc, bool clientWins) internal returns (address agreementAddr) {
        usdc.mint(cli, 1_000_000 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, exc, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(exc);
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);

        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreementAddr, clientWins);
    }

    // Registers 3 extra arbiters (beyond the default `arbiter`) so appeal quorum
    // (APPEAL_MIN_VOTES = 3 others) is always reachable in appeal tests.
    function _addAppealQuorumArbiters() internal returns (address a2, address a3, address a4) {
        a2 = address(0x30);
        a3 = address(0x31);
        a4 = address(0x32);
        ArbiterRegistryFacet(address(diamond)).addArbiter(a2);
        _bondSeat(a2);
        ArbiterRegistryFacet(address(diamond)).addArbiter(a3);
        _bondSeat(a3);
        ArbiterRegistryFacet(address(diamond)).addArbiter(a4);
        _bondSeat(a4);
    }

    // The new flow: the arbiter through the Diamond (submitVerdict → finalizeVerdict)
    function _resolveDispute(address agreementAddr, bool clientWins) internal {
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreementAddr, clientWins);
        vm.warp(block.timestamp + 72 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);
    }

    // Completes a full deal (fund -> activate -> markDone -> release) between the given
    // client/executor pair. Assumes cli already holds enough USDC (setUp mints 10000 USDC
    // to the shared `client` constant; fresh addresses need minting by the caller first).
    function _completeDeal(address cli, address exc) internal returns (address agreementAddr) {
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, exc, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(exc);
        Agreement(agreementAddr).activate();
        vm.prank(exc);
        Agreement(agreementAddr).markDone();
        vm.prank(cli);
        Agreement(agreementAddr).release();
    }

    // Grows `party`'s XP to >= targetXP via clean, fully-released deals, cycling to a fresh
    // counterparty every 3 deals so the per-pair win cap (MAX_WINS_PAIR) never stalls
    // progress. `asExecutor` selects which role `party` plays; the counterparty always takes
    // the other role and gets freshly minted USDC. `baseAddr` seeds the counterparty address
    // range so parallel calls in different tests never collide.
    //
    // NOTE: Under Mechanism 1 (Reputation gate), each counterparty's *first* deal doesn't
    // count toward `party`'s cleanStreak (counterparty starts at 0 XP, so the client-XP
    // check fails). Without a warm-up, 1 in every 3 deals silently stops counting, and
    // by the time XP crosses targetXP, the streak is well behind what callers expect.
    // A one-deal warm-up per counterparty (pushing its XP past MIN_COUNTERPARTY_XP)
    // restores the invariant: every counted deal moves the streak.
    function _growXP(address party, bool asExecutor, uint256 targetXP, uint256 baseAddr) internal {
        usdc.mint(party, 1_000_000 * 10**6);
        uint256 dealIndex = 0;
        address lastCounterparty = address(0);
        while (ReputationFacet(address(diamond)).getXP(party) < targetXP) {
            address counterparty = address(uint160(baseAddr + dealIndex / 3));
            if (counterparty != lastCounterparty) {
                usdc.mint(counterparty, 1_000_000 * 10**6);
                // Warm up: Mechanism 1 requires a deal's client to already have
                // >= MIN_COUNTERPARTY_XP (50) for it to count toward cleanStreak.
                // A single throwaway deal pushes counterparty past that threshold
                // before it's used for real below — otherwise 1 in every 3 deals
                // in this loop would silently not count toward party's streak.
                address throwaway = address(uint160(uint256(keccak256(abi.encodePacked("growxp-warmup", counterparty)))));
                usdc.mint(throwaway, 1_000_000 * 10**6);
                _completeDeal(counterparty, throwaway);
                lastCounterparty = counterparty;
            }
            if (asExecutor) {
                _completeDeal(counterparty, party);
            } else {
                _completeDeal(party, counterparty);
            }
            dealIndex++;
        }
    }

    // Gives `cli` a single throwaway completed deal so its own XP crosses
    // MIN_COUNTERPARTY_XP (50) before it's used as the client in a deal whose
    // cleanStreak effect on the executor is under test. `cli` itself starts at
    // 0 XP in every fresh test, and Mechanism 1 requires prior standing, not
    // standing gained from the deal being measured. Caller must ensure `cli`
    // already holds USDC (setUp's shared `client` does; fresh addresses need
    // `usdc.mint(cli, ...)` first).
    function _warmUpClientXP(address cli) internal {
        address throwaway = address(uint160(uint256(keccak256(abi.encodePacked("warmup", cli)))));
        _completeDeal(cli, throwaway);
    }

    // ============ DIAMOND PROXY TESTS ============
    
    function testDiamondOwner() public view {
        assertEq(OwnershipFacet(address(diamond)).owner(), owner);
    }
    
    function testDiamondLoupe() public view {
        IDiamondLoupe.Facet[] memory facets = DiamondLoupeFacet(address(diamond)).facets();
        assertGe(facets.length, 5);
    }
    
    function testDiamondSupportsInterface() public view {
        assertTrue(DiamondLoupeFacet(address(diamond)).supportsInterface(type(IERC165).interfaceId));
        assertTrue(DiamondLoupeFacet(address(diamond)).supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(DiamondLoupeFacet(address(diamond)).supportsInterface(type(IDiamondLoupe).interfaceId));
        // An unknown interface — false
        assertFalse(DiamondLoupeFacet(address(diamond)).supportsInterface(0xdeadbeef));
        // ERC-721 / ERC721Metadata are not checked here — this harness does not
        // mount JobReceiptFacet, so a true would only be correct for the mapping
        // and not for a genuinely working ERC-721. See
        // testJobReceiptFacetSupportsInterface in the Boards suite, where the facet
        // really is wired up.
    }
    
    // ============ REGISTRY FACET TESTS ============
    
    function testRegistryInit() public view {
        assertEq(RegistryFacet(address(diamond)).authorizedFactory(), address(diamond));
    }
    
    function testRegistryInitRevertIfAlreadyInitialized() public {
        vm.expectRevert(RegistryFacet.AlreadyInitialized.selector);
        RegistryFacet(address(diamond)).initRegistry(address(0x5));
    }
    
    function testRegistryTotalAgreements() public view {
        assertEq(RegistryFacet(address(diamond)).totalAgreements(), 0);
    }
    
    function testRegistryRegister() public {
        vm.prank(address(diamond));
        RegistryFacet(address(diamond)).register(address(0x100), client, executor, AMOUNT);
        
        assertTrue(RegistryFacet(address(diamond)).hasActivePair(client, executor));
        assertEq(RegistryFacet(address(diamond)).getActivePair(client, executor), address(0x100));
        assertEq(RegistryFacet(address(diamond)).totalAgreements(), 1);
    }
    
    function testRegistryRegisterRevertIfNotFactory() public {
        vm.prank(client);
        vm.expectRevert(RegistryFacet.OnlyAuthorizedFactory.selector);
        RegistryFacet(address(diamond)).register(address(0x100), client, executor, AMOUNT);
    }
    
    function testRegistryRegisterRevertIfActiveDealExists() public {
        vm.prank(address(diamond));
        RegistryFacet(address(diamond)).register(address(0x100), client, executor, AMOUNT);
        
        vm.prank(address(diamond));
        vm.expectRevert(RegistryFacet.ActiveDealAlreadyExists.selector);
        RegistryFacet(address(diamond)).register(address(0x101), client, executor, AMOUNT);
    }
    
    function testRegistryUpdateStatus() public {
        vm.prank(address(diamond));
        RegistryFacet(address(diamond)).register(address(0x100), client, executor, AMOUNT);
        
        vm.prank(address(0x100));
        RegistryFacet(address(diamond)).updateStatus(address(0x100), RegistryStorage.AgreementStatus.COMPLETED);
        
        RegistryStorage.AgreementRecord memory record = RegistryFacet(address(diamond)).getRecord(address(0x100));
        assertEq(uint256(record.status), uint256(RegistryStorage.AgreementStatus.COMPLETED));
        assertFalse(RegistryFacet(address(diamond)).hasActivePair(client, executor));
    }
    
    function testRegistryUpdateStatusRevertIfNotAgreement() public {
        vm.prank(address(diamond));
        RegistryFacet(address(diamond)).register(address(0x100), client, executor, AMOUNT);
        
        vm.prank(client);
        vm.expectRevert(RegistryFacet.OnlyAgreementItself.selector);
        RegistryFacet(address(diamond)).updateStatus(address(0x100), RegistryStorage.AgreementStatus.COMPLETED);
    }
    
    function testRegistryGetByClient() public {
        vm.prank(address(diamond));
        RegistryFacet(address(diamond)).register(address(0x100), client, executor, AMOUNT);
        
        RegistryStorage.AgreementRecord[] memory records = RegistryFacet(address(diamond)).getByClient(client);
        assertEq(records.length, 1);
        assertEq(records[0].agreement, address(0x100));
    }
    
    function testRegistryGetByExecutor() public {
        vm.prank(address(diamond));
        RegistryFacet(address(diamond)).register(address(0x100), client, executor, AMOUNT);
        
        RegistryStorage.AgreementRecord[] memory records = RegistryFacet(address(diamond)).getByExecutor(executor);
        assertEq(records.length, 1);
    }
    
    function testRegistryGetActive() public {
        vm.prank(address(diamond));
        RegistryFacet(address(diamond)).register(address(0x100), client, executor, AMOUNT);
        
        RegistryStorage.AgreementRecord[] memory active = RegistryFacet(address(diamond)).getActive();
        assertEq(active.length, 1);
    }
    
    // ============ FACTORY FACET TESTS ============
    
    function testFactoryInit() public view {
        assertEq(FactoryFacet(address(diamond)).getUsdc(), address(usdc));
        assertEq(FactoryFacet(address(diamond)).getFeeRecipient(), feeRecipient);
        assertFalse(false);
    }
    
    function testFactoryDeployAgreement() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        
        vm.prank(address(diamond));
        address agreement = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        assertTrue(agreement != address(0));
        assertTrue(RegistryFacet(address(diamond)).hasActivePair(client, executor));
    }
    
    // testFactoryDeployRevertIfPaused removed — pause mechanism was removed from FactoryFacet
    
    function testFactoryDeployRevertIfZeroAddress() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.FactoryZeroAddress.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            address(0), executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
    }
    
    function testFactoryDeployRevertIfClientEqualsExecutor() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.ClientEqualsExecutor.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, client, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
    }
    
    function testFactoryDeployRevertIfZeroAmount() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.ZeroAmount.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, 0, DEADLINE, TERMS_HASH, 0
        );
    }
    
    function testFactoryDeployRevertIfZeroDeadline() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.ZeroDeadline.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, 0, TERMS_HASH, 0
        );
    }
    
    function testFactoryDeployRevertIfInvalidRegion() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.InvalidRegion.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 7
        );
    }
    
    function testFactoryDeployRevertIfActiveDealExists() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        vm.expectRevert(FactoryFacet.ActiveDealExists.selector);
        FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
    }
    
    function testFactoryAdminFunctions() public {
        FactoryFacet(address(diamond)).setFeeRecipient(address(0x5));
        assertEq(FactoryFacet(address(diamond)).getFeeRecipient(), address(0x5));

        FactoryFacet(address(diamond)).setTrustedForwarder(address(0x6));
        assertEq(FactoryFacet(address(diamond)).getTrustedForwarder(), address(0x6));
    }

    function testFactoryAdminRevertIfNotOwner() public {
        // The onlyOwner gate is checked through setFeeRecipient: setRegionFee,
        // which used to carry this check, now unconditionally reverts FeeNotRegional
        // and proves nothing about the owner any more.
        vm.prank(client);
        vm.expectRevert(FactoryFacet.NotOwner.selector);
        FactoryFacet(address(diamond)).setFeeRecipient(address(0x5));
    }
    
    // ============ AGREEMENT TESTS ============
    
    function testFullLifecycle() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        Agreement agreement = Agreement(agreementAddr);
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        agreement.fund();
        
        assertEq(uint256(agreement.status()), uint256(Agreement.Status.FUNDED));
        assertEq(usdc.balanceOf(agreementAddr), AMOUNT);
        
        vm.prank(executor);
        agreement.activate();
        
        assertEq(uint256(agreement.status()), uint256(Agreement.Status.ACTIVE));
        
        vm.prank(executor);
        agreement.markDone();
        
        uint256 executorBalanceBefore = usdc.balanceOf(executor);
        vm.prank(client);
        agreement.release();
        
        // Status is COMPLETED (3) but status() view returns based on timers
        // After release, NFT is burned and status should be COMPLETED
        assertEq(usdc.balanceOf(executor), executorBalanceBefore + AMOUNT);
        assertEq(usdc.balanceOf(executor), executorBalanceBefore + AMOUNT);
    }

    // ============ CLEAN STREAK / PHASE-2 XP GATING ============

    function testCleanStreakIncrementsOnCompleted() public {
        _warmUpClientXP(client);
        address freshExecutor = address(uint160(30001));
        _completeDeal(client, freshExecutor);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);
    }

    function testCleanStreakUnchangedOnExecutorWonDispute() public {
        _warmUpClientXP(client);
        address freshExecutor = address(uint160(30002));
        _completeDeal(client, freshExecutor);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);

        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, freshExecutor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        vm.prank(freshExecutor);
        Agreement(agreementAddr).activate();
        vm.prank(freshExecutor);
        Agreement(agreementAddr).raiseDispute();
        _claimDispute(agreementAddr);
        _resolveDispute(agreementAddr, false); // executor wins

        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);
    }

    function testCleanStreakResetsOnExecutorLostDispute() public {
        _warmUpClientXP(client);
        address freshExecutor = address(uint160(30003));
        _completeDeal(client, freshExecutor);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);

        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, freshExecutor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        vm.prank(freshExecutor);
        Agreement(agreementAddr).activate();
        vm.prank(client);
        Agreement(agreementAddr).raiseDispute();
        _claimDispute(agreementAddr);
        _resolveDispute(agreementAddr, true); // client wins — executor loses

        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 0);
    }

    function testNotifyExecutorFaultResetsStreak() public {
        _warmUpClientXP(client);
        address freshExecutor = address(uint160(34001));
        _completeDeal(client, freshExecutor);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);

        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, freshExecutor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );

        vm.prank(agreementAddr);
        ReputationFacet(address(diamond)).notifyExecutorFault(agreementAddr);

        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 0);
    }

    function testNotifyExecutorFaultRevertsIfNotAgreement() public {
        vm.expectRevert(ReputationFacet.NotAgreement.selector);
        ReputationFacet(address(diamond)).notifyExecutorFault(address(0xBAD));
    }

    /// ⚠️ INVERTED ON 20 SEPTEMBER 2026, AND IT IS ONE OF THE LOCKS ON PHASE 2
    /// STAYING DEAD. It used to assert that a client past 1000 XP earned NOTHING
    /// from any further deal. That rule existed to slow the climb toward the
    /// 3 000 XP that opened the arbiter corps; the corps stopped asking for XP,
    /// so the brake stood in front of nothing and stopped an honest client's
    /// standing from growing while telling them nothing about why.
    ///
    /// Put Phase 2 back and this goes red: the client's XP would stop moving.
    function testClientXpKeepsGrowingPastTheOldPhase2Line() public {
        address bigClient = address(uint160(31000));
        _growXP(bigClient, false, 1000, 31500);
        uint256 xpAtThreshold = ReputationFacet(address(diamond)).getXP(bigClient);
        assertGe(xpAtThreshold, 1000, "setup: he is past the line the brake used to stand on");

        address freshExecutor = address(uint160(31999));
        _completeDeal(bigClient, freshExecutor);

        assertGt(
            ReputationFacet(address(diamond)).getXP(bigClient),
            xpAtThreshold,
            "a client past 1000 XP keeps earning - the Phase-2 freeze is gone"
        );
    }

    /// ⚠️ INVERTED ON 20 SEPTEMBER 2026 — the second Phase-2 lock. It used to
    /// assert that an executor past 1000 XP earned NOTHING until his clean
    /// streak was back at ten. That gate is gone with the rest of Phase 2, and
    /// what stands in its place is the plain rule: a deal pays if the
    /// counterparty carried standing, whatever the streak is doing.
    ///
    /// The scene still BREAKS the streak with a lost dispute, because the whole
    /// value of it is the contrast: streak at zero, XP still moving. Put
    /// Phase 2 back and the second assertion goes red.
    function testExecutorXpIsNoLongerGatedByTheStreak() public {
        address bigExecutor = address(uint160(32000));
        _growXP(bigExecutor, true, 1000, 32500);
        uint256 xpAtThreshold = ReputationFacet(address(diamond)).getXP(bigExecutor);
        assertGe(xpAtThreshold, 1000, "setup: past the line the brake used to stand on");

        // Break the streak with a lost dispute.
        address disputeClient = address(uint160(32900));
        usdc.mint(disputeClient, 1_000_000 * 10**6);
        vm.prank(disputeClient);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address disputedAgreement = FactoryFacet(address(diamond)).deployAgreement(
            disputeClient, bigExecutor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(disputeClient);
        usdc.approve(disputedAgreement, AMOUNT);
        vm.prank(disputeClient);
        Agreement(disputedAgreement).fund();
        vm.prank(bigExecutor);
        Agreement(disputedAgreement).activate();
        vm.prank(disputeClient);
        Agreement(disputedAgreement).raiseDispute();
        _claimDispute(disputedAgreement);
        _resolveDispute(disputedAgreement, true); // client wins - executor loses, streak resets

        assertEq(
            ReputationFacet(address(diamond)).getCleanStreak(bigExecutor), 0,
            "setup: the run really is broken"
        );

        // One clean deal, with a counterparty who already carries standing.
        // Under Phase 2 this paid nothing (streak 0 < 10). Now it pays.
        uint256 xpAfterLoss = ReputationFacet(address(diamond)).getXP(bigExecutor);
        address warmClient = address(uint160(32950));
        usdc.mint(warmClient, 1_000_000 * 10**6);
        _warmUpClientXP(warmClient);
        _completeDeal(warmClient, bigExecutor);

        assertGt(
            ReputationFacet(address(diamond)).getXP(bigExecutor), xpAfterLoss,
            "a broken streak no longer freezes an executor's standing"
        );
        assertEq(
            ReputationFacet(address(diamond)).getCleanStreak(bigExecutor), 1,
            "and the streak starts again from one, as it always did"
        );
    }
    function testCleanStreakDoesNotIncrementWhenClientBelowMinCounterpartyXP() public {
        address freshClient = address(uint160(35001));
        address freshExecutor = address(uint160(35002));
        usdc.mint(freshClient, 1_000_000 * 10**6);
        _completeDeal(freshClient, freshExecutor);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 0);
    }

    function testCleanStreakIncrementsOnceClientAboveMinCounterpartyXP() public {
        address warmClient = address(uint160(35003));
        address freshExecutor = address(uint160(35004));
        usdc.mint(warmClient, 1_000_000 * 10**6);
        _warmUpClientXP(warmClient);
        assertGe(ReputationFacet(address(diamond)).getXP(warmClient), 50);

        _completeDeal(warmClient, freshExecutor);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);
    }

    /// The third of the Phase-2 scenes, inverted the same way and for the same
    /// reason. A deal with a BRAND NEW counterparty used to buy a veteran
    /// executor nothing at all. It still buys no clean STREAK — that rule is
    /// untouched and is what stops a ring of fresh wallets — but it now pays XP
    /// like any other deal.
    ///
    /// ⚠️ The two halves are deliberately asserted together. "XP moves, streak
    /// does not" is the exact shape of the change; either half alone would stay
    /// green under a mistake in the other.
    function testAFreshCounterpartyPaysXpButStillBuysNoStreak() public {
        address bigExecutor = address(uint160(35100));
        _growXP(bigExecutor, true, 1000, 35500);
        assertGe(ReputationFacet(address(diamond)).getXP(bigExecutor), 1000);

        uint256 xpBefore     = ReputationFacet(address(diamond)).getXP(bigExecutor);
        uint256 streakBefore = ReputationFacet(address(diamond)).getCleanStreak(bigExecutor);

        address freshClient = address(uint160(35999));
        usdc.mint(freshClient, 1_000_000 * 10**6);
        _completeDeal(freshClient, bigExecutor);

        assertGt(
            ReputationFacet(address(diamond)).getXP(bigExecutor), xpBefore,
            "the Phase-2 gate is gone: the deal pays XP"
        );
        assertEq(
            ReputationFacet(address(diamond)).getCleanStreak(bigExecutor), streakBefore,
            "and the counterparty rule is NOT gone: a newcomer buys no streak"
        );

        // And the person is told so, by name, instead of being left to work it
        // out. The running total is the half a screen can read after a reload.
        (, uint256 stalled, uint256 minCounterpartyXP) =
            ReputationFacet(address(diamond)).getStreakStanding(bigExecutor);
        assertEq(stalled, 1, "the deal that bought no streak is counted and visible");
        assertEq(minCounterpartyXP, 50, "and the rule that did it is readable from the same call");
    }

    // ============ ARBITER DEMOTION ============

    /// Governance handed over through the three doors the chain now insists on
    /// (decisions 50 and 51, 26 August 2026), in this order and no other:
    ///
    ///   1. the corps has to be EARNED — `activateDAO()` refuses below
    ///      DAO_THRESHOLD unique active users. The counter is written straight
    ///      into ReputationStorage here: growing ten thousand real users would
    ///      cost more than every other test in this file put together, and what
    ///      is under test in these scenes is the door, not the counter.
    ///   2. the successor is PROPOSED by the owner, and
    ///   3. the successor CONFIRMS by sending his own transaction — until then
    ///      `daoAddress` is still zero and `activateDAO()` refuses.
    ///
    /// Before 26 August this was two lines and no threshold; the shape of the
    /// helper is the change itself.
    function _handGovernanceToDao(address dao) internal {
        // ReputationStorage.POSITION, slot 8 (uniqueActiveUsers) — the same
        // offset four other test files pin by brute force.
        vm.store(
            address(diamond),
            bytes32(
                uint256(0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400) + 8
            ),
            bytes32(ArbiterRegistryFacet(address(diamond)).getDaoThreshold())
        );
        ArbiterRegistryFacet(address(diamond)).setDAOAddress(dao);
        vm.prank(dao);
        ArbiterRegistryFacet(address(diamond)).acceptDAOAddress();
        _seedHandoverLiveness(address(diamond));
        ArbiterRegistryFacet(address(diamond)).activateDAO();
        assertTrue(ArbiterRegistryFacet(address(diamond)).isDaoActive(), "setup: governance is live");
    }

    function testApplyAsArbiterRevertsIfStreakTooLow() public {
        _handGovernanceToDao(address(0xDA0));

        address candidate = address(uint160(40000));
        _growXP(candidate, true, 3000, 40500);
        // Break the streak right before applying, without dropping XP below 3000: one lost
        // dispute costs LOSS_XP_PENALTY (50), which candidate's balance easily absorbs.
        address disputeClient = address(uint160(40900));
        usdc.mint(disputeClient, 1_000_000 * 10**6);
        vm.prank(disputeClient);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address disputedAgreement = FactoryFacet(address(diamond)).deployAgreement(
            disputeClient, candidate, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(disputeClient);
        usdc.approve(disputedAgreement, AMOUNT);
        vm.prank(disputeClient);
        Agreement(disputedAgreement).fund();
        vm.prank(candidate);
        Agreement(disputedAgreement).activate();
        vm.prank(disputeClient);
        Agreement(disputedAgreement).raiseDispute();
        _claimDispute(disputedAgreement);
        _resolveDispute(disputedAgreement, true); // candidate loses — streak resets to 0

        assertGe(ReputationFacet(address(diamond)).getXP(candidate), 3000);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(candidate), 0);

        vm.prank(candidate);
        vm.expectRevert(abi.encodeWithSelector(ArbiterRegistryFacet.InsufficientCleanStreak.selector, 0, 5));
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();
    }

    function testApplyAsArbiterSucceedsWithBothConditions() public {
        _handGovernanceToDao(address(0xDA0));

        address candidate = address(uint160(41000));
        _growXP(candidate, true, 3000, 41500);
        assertGe(ReputationFacet(address(diamond)).getXP(candidate), 3000);
        assertGe(ReputationFacet(address(diamond)).getCleanStreak(candidate), 10);

        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        assertTrue(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(candidate));
        // Zero, and it is the point rather than an omission: a seat costs
        // nothing since 22 September 2026.
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), 0);
    }

    /// ⚠️ THE PREMISE OF THE PUBLIC DOCUMENT, TURNED ROUND (22 September 2026).
    ///
    /// This scene used to assert the opposite: `applyAsArbiter` refusing
    /// `DAONotActive` while governance slept, because docs/DECENTRALIZATION.md
    /// said the corps could be entered by no road but the owner's hand. That
    /// line is the line the owner's decision removed — the ladder "work
    /// cleanly, then judge" ended in a wall, since the automatic door unlocked
    /// only after the handover it was meant to prepare for.
    ///
    /// What is measured now is the same door from the other side: governance
    /// asleep, a candidate with the record, and he walks in. The mirror above
    /// (testApplyAsArbiterSucceedsWithBothConditions) does the same with the DAO
    /// switched on, so the pair says the door does not care either way.
    ///
    /// ⚠️ THE APPOINTED LOCK FOR THIS CHANGE IS NOT THIS FILE. It is
    /// test/ArbiterSelfEnrolment.t.sol, which also drives the door through a
    /// real forwarder from a wallet with no ETH. This scene is kept because the
    /// old assertion lived here and a reader who goes looking for it must find
    /// what replaced it, not a gap.
    function testApplyAsArbiterWorksWhileTheDaoSleeps() public {
        // The DAO is NOT switched on — not by address, not by flag, not by threshold.
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isDaoActive(),
            "setup: the DAO is asleep"
        );

        address candidate = address(uint160(41100));
        _growXP(candidate, true, 3000, 41600);
        assertGe(ReputationFacet(address(diamond)).getXP(candidate), 3000);
        assertGe(ReputationFacet(address(diamond)).getCleanStreak(candidate), 10);

        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        assertTrue(
            ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(candidate),
            "the ladder still ends in a wall"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), 0,
            "and no bond was taken from him"
        );
    }

    function testArbiterDemotedAfterThreeOverturns() public {
        address flakyArbiter = address(uint160(42000));
        ArbiterRegistryFacet(address(diamond)).addArbiter(flakyArbiter);
        _bondSeat(flakyArbiter);

        _disputeAndOverturn(address(uint160(42100)), address(uint160(42200)), flakyArbiter);
        assertTrue(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));

        _disputeAndOverturn(address(uint160(42101)), address(uint160(42201)), flakyArbiter);
        assertTrue(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));

        _disputeAndOverturn(address(uint160(42102)), address(uint160(42202)), flakyArbiter);

        // ⚠️ THE SCENE WAS REBUILT WHEN THE THIRD MISTAKE STOPPED REMOVING.
        // It now SUSPENDS AND ACCUSES in the chain's name, and the takedown goes
        // through the common door after 48 hours. The counter is DELIBERATELY not
        // reset: a streak of judging mistakes has not ended just because the chain
        // noticed it. The button does not need the counter anyway — it reads the
        // RECORD and fires at zero, and ten lines below it is pressed in this very
        // scene.
        //
        // ⚠️ AND THE XP LINE WAS TURNED OVER ON 21 SEPTEMBER 2026. It used to
        // read `assertEq(getXP(flakyArbiter), 2500)` — the flat landing point the
        // accusation used to write. The reset is gone: the accusation takes the
        // seat's standing, not the record of work. This man never had XP to begin
        // with (he was seated by hand, and a judge earns none by judging), so what
        // the assertion says out loud is that the chain did NOT put 2500 there.
        assertTrue(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));
        assertEq(
            ReputationFacet(address(diamond)).getXP(flakyArbiter), 0,
            "the accusation writes nothing into the record of work"
        );
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(flakyArbiter), 3);
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(flakyArbiter));
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).isSuspended(flakyArbiter));

        // And the second half of the same scene: after the pause anybody may press.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(address(uint160(42999)));
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(flakyArbiter);

        assertFalse(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(flakyArbiter), 0);
    }

    /// ⚠️ THIS SCENE WAS TURNED OVER ON 21 SEPTEMBER 2026, NAME AND ALL. It
    /// used to be `testArbiterDemotionResetIsFlatNotSubtractive`, and it held the
    /// opposite rule: an arbiter with a large earned balance "must still land at
    /// exactly 2500", flat, whatever he had. That was the point of
    /// DEMOTION_XP_RESET — to drop a punished man below the entrance threshold
    /// (3000) so the way back into the corps had to be earned a second time.
    ///
    /// WHY THE RULE CHANGED. The entrance stopped asking for XP on 20 September
    /// 2026 and asks for the clean streak, which a removal already takes
    /// (`test_ARemovalForCauseTakesTheKeyToTheCorps`) — so the barrier the reset
    /// bought is there without it. What the reset still did was rewrite a record
    /// of work already done, backwards, to make a punishment land. Experience is
    /// how much a man worked; editing it is a forgery of history, not a penalty.
    /// The penalty is the forfeited bond, the lost seat, the zeroed clean streak
    /// and a permanent public record of the removal. Renamed rather than deleted,
    /// and the old name is written here on purpose: the record quotes it.
    ///
    /// ⚠️ WHAT IS *NOT* BEING SAID: that judging badly is free. It is not.
    /// OVERTURN_XP_SLASH (200) still takes points for EACH overturn at the moment
    /// that one mistake is proven, and this scene counts all three of them out —
    /// so a mutation that quietly removed the per-mistake slash reddens here too,
    /// from the other side.
    ///
    /// THE MUTATION THIS IS WRITTEN AGAINST: put
    /// `rep.xp[arbiterAddr] = 2500;` back at the top of
    /// `ArbiterRegistryFacet._suspendAndAccuse` and leave everything else alone.
    function testAutomaticDemotionLeavesTheRecordOfWorkAlone() public {
        address veteranArbiter = address(uint160(43000));
        _growXP(veteranArbiter, true, 10_000, 43500);
        uint256 xpBeforeDemotion = ReputationFacet(address(diamond)).getXP(veteranArbiter);
        assertGe(xpBeforeDemotion, 10_000, "setup: he carries a real record of work");
        ArbiterRegistryFacet(address(diamond)).addArbiter(veteranArbiter);
        _bondSeat(veteranArbiter);

        _disputeAndOverturn(address(uint160(43100)), address(uint160(43200)), veteranArbiter);
        _disputeAndOverturn(address(uint160(43101)), address(uint160(43201)), veteranArbiter);
        _disputeAndOverturn(address(uint160(43102)), address(uint160(43202)), veteranArbiter);

        // Three proven mistakes, three slashes of OVERTURN_XP_SLASH, and NOTHING
        // ELSE: no landing point, no flattening, no rewrite of what he earned.
        // Spelled as "what he had minus the three charges" rather than as a
        // literal, so that a change to either number is visible as itself.
        assertEq(
            ReputationFacet(address(diamond)).getXP(veteranArbiter),
            xpBeforeDemotion - 3 * 200,
            "the accusation charges for the three mistakes and rewrites nothing else"
        );
        assertGe(
            ReputationFacet(address(diamond)).getXP(veteranArbiter), 9_000,
            "and he is emphatically NOT put back at the old landing point of 2500"
        );
    }

    /// ⚠️ THE SEAT IS FREE SINCE 22 SEPTEMBER 2026, and this scene is the
    /// inverse of the one it replaces (`testApplyAsArbiterPullsBond`): the door
    /// must take NOTHING. The money an arbiter puts at risk is posted per CASE,
    /// inside `claimDispute`.
    function testApplyAsArbiterTakesNothing() public {
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(45000));
        _growXP(candidate, true, 3000, 45500);

        uint256 balanceBefore = usdc.balanceOf(candidate);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), 0);
        assertEq(usdc.balanceOf(candidate), balanceBefore, "not a cent left his wallet");
    }

    /// And it does not need an allowance either. This is the scene that used to
    /// be `testApplyAsArbiterRevertsWithoutBondApproval`: an empty allowance was
    /// the reason the door refused, and now it is not a reason at all.
    function testApplyAsArbiterNeedsNoAllowance() public {
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(45100));
        _growXP(candidate, true, 3000, 45600);

        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        assertTrue(
            ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(candidate),
            "a man who granted the diamond nothing is seated all the same"
        );
    }

    /// ⚠️ REWRITTEN 22 SEPTEMBER 2026, AND THE TITLE IS THE CHANGE. A removal
    /// used to burn the seat bond into the arbiter bank. There is no seat bond,
    /// so it burns nothing — and that is a consequence of the owner's decision
    /// rather than a gap: the sanction for a bad arbiter is the record, the
    /// suspension and the loss of the seat. The money an arbiter risks belongs
    /// to a CASE and is drawn only by an appeal that overturns him.
    ///
    /// The two halves the old scene measured still hold in order: the chain's
    /// accusation touches no money, and neither does the removal.
    function testDemotionForfeitsNothingBecauseTheSeatCostsNothing() public {
        // ⚠️ THE PANEL IS SEATED BEFORE THE HANDOVER, AND IT HAS TO BE (9 October
        // 2026). The mistake run below reaches its overturns through the appeal
        // panel now, and `addArbiter` answers `SeatingHandedOver` once governance
        // is live — measured: this scene was the one red in this file that said so.
        _ensureAppealPanel();
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(45200));
        _growXP(candidate, true, 3000, 45700);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();
        // He claims three disputes below, and each claim asks him for that
        // case's bond.
        _bondSeat(candidate);

        _disputeAndOverturn(address(uint160(45800)), address(uint160(45900)), candidate);
        _disputeAndOverturn(address(uint160(45801)), address(uint160(45901)), candidate);
        _disputeAndOverturn(address(uint160(45802)), address(uint160(45902)), candidate);

        // ⚠️ THE BANK IS READ AFTER THE MISTAKE RUN, NOT BEFORE IT (9 October
        // 2026), and the move is the whole point rather than a convenience. This
        // scene asks ONE question — does a REMOVAL forfeit money — and since the
        // overturns are the appeal panel's, each of them now puts an indivisible
        // remainder of the appellant's deposit into the bank on purpose
        // (`resolveAppeal`: deposit / votes, the remainder to the bank). Measured:
        // three rounds left 6 base units there, and with the baseline taken before
        // the run this test failed reading "the bank did not grow: 6 != 0" — it was
        // blaming the removal for the appeal's arithmetic.
        //
        // Taken here, the comparison spans exactly the removal and nothing else,
        // which is what it was always meant to measure.
        uint256 vaultBefore = ArbiterVaultFacet(address(diamond)).getVaultBalance();

        // ⚠️ THE BOND BURNS ON REMOVAL, NOT ON ACCUSATION. Until the pause is over
        // the person is still an arbiter and the money is still theirs — an
        // accusation is not a punishment.
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), 0,
            "there is no seat bond for an accusation to touch"
        );

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(address(uint160(45999)));
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(candidate);

        assertFalse(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(candidate));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), 0);
        assertEq(
            ArbiterVaultFacet(address(diamond)).getVaultBalance(), vaultBefore,
            "the bank did not grow: a removal forfeits nothing now"
        );
    }

    /// ⚠️ LEAVING PAYS NOTHING SINCE 22 SEPTEMBER 2026, and that is the whole
    /// of what changed: a seat holds no money to give back. It still clears the
    /// status, which is what the door is for, and the man walks out owning
    /// exactly what he owned walking in.
    function testResignAsArbiterPaysNothingAndClearsStatus() public {
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(45300));
        _growXP(candidate, true, 3000, 45400);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        uint256 balanceAfterApply = usdc.balanceOf(candidate);

        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();

        assertFalse(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(candidate));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), 0);
        assertEq(usdc.balanceOf(candidate), balanceAfterApply, "leaving the corps moves no money");
    }

    function testResignAsArbiterRevertsIfNotArbiter() public {
        vm.prank(address(uint160(45999)));
        vm.expectRevert(ArbiterRegistryFacet.NotAnArbiter.selector);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
    }

    // testRemoveArbiterRefundsBond / testRemoveArbiterNoOpsOnZeroBond were deleted
    // on 15 August 2026: removeArbiter was taken off the facet entirely. Refunding
    // the bond is still covered by testResignAsArbiterRefundsBondAndClearsStatus
    // above — resignAsArbiter outlives that change and calls the same
    // seat-clearing helper. Forfeiting the bond on a removal for cause (the
    // opposite behaviour: not a refund but a seizure into the arbiter vault) is
    // the new behaviour of removeArbiterForCause. ⚠️ The first time round, the
    // same word "covered" stood here with not one line of actual cover behind it
    // — it is now genuinely covered by the named test_RemovalForCauseForfeitsTheBond
    // in the ArbiterRemovalForCause suite (which checks getArbiterBond → 0,
    // getVaultBalance grown by exactly the forfeit, and bondForfeited in the
    // event).

    function testClaimDisputeIncrementsOpenClaimCount() public {
        address cli = address(uint160(46000));
        usdc.mint(cli, 1_000_000 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, address(uint160(46001)), arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(address(uint160(46001)));
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(arbiter), 1);
    }

    function testReleaseDisputeClaimDecrementsOpenClaimCount() public {
        address cli = address(uint160(46100));
        usdc.mint(cli, 1_000_000 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, address(uint160(46101)), arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(address(uint160(46101)));
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(arbiter), 1);

        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(agreementAddr);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(arbiter), 0);
    }

    function testFinalizeVerdictDecrementsOpenClaimCount() public {
        address cli = address(uint160(46200));
        usdc.mint(cli, 1_000_000 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, address(uint160(46201)), arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(address(uint160(46201)));
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(arbiter), 1);

        _resolveDispute(agreementAddr, true);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(arbiter), 0);
    }

    function testArbiterTimeoutDecrementsOpenClaimCount() public {
        address flakyArbiter = address(uint160(46300));
        ArbiterRegistryFacet(address(diamond)).addArbiter(flakyArbiter);
        _bondSeat(flakyArbiter);

        _disputeAndArbiterTimeout(address(uint160(46400)), address(uint160(46500)), flakyArbiter, 10_000_000);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(flakyArbiter), 0);
    }

    function testResignAsArbiterRevertsWithOpenClaim() public {
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(46600));
        _growXP(candidate, true, 3000, 46700);
        vm.prank(candidate);
        usdc.approve(address(diamond), ARBITER_BOND);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        address cli = address(uint160(46800));
        usdc.mint(cli, 1_000_000 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, address(uint160(46801)), candidate, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(address(uint160(46801)));
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDisputeAs(agreementAddr, candidate);

        vm.prank(candidate);
        vm.expectRevert(ArbiterRegistryFacet.HasOpenDisputeClaims.selector);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
    }

    function testResignAsArbiterSucceedsAfterClaimResolved() public {
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(46900));
        _growXP(candidate, true, 3000, 47000);
        vm.prank(candidate);
        usdc.approve(address(diamond), ARBITER_BOND);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        address cli = address(uint160(47100));
        usdc.mint(cli, 1_000_000 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, address(uint160(47101)), candidate, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(address(uint160(47101)));
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDisputeAs(agreementAddr, candidate);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreementAddr, true);
        vm.warp(block.timestamp + 72 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(candidate), 0);

        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();

        assertFalse(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(candidate));
    }

    function testFinalizedVerdictResetsMistakeStreak() public {
        address recoveringArbiter = address(uint160(44000));
        ArbiterRegistryFacet(address(diamond)).addArbiter(recoveringArbiter);
        _bondSeat(recoveringArbiter);

        // One overturned verdict — mistake streak becomes 1.
        //
        // ⚠️ THE HAND'S PRESS IS GONE (9 October 2026), so the overturn is the
        // PANEL'S, and the sequence is no longer spelled out here: the shared
        // `_disputeAndOverturn` builds the same deal and ends with
        // `resolveAppeal` booking the mistake. This scene's subject is the RESET
        // asserted below, never how the mistake was earned, so it takes the
        // helper rather than carrying its own copy of the appeal plumbing.
        _disputeAndOverturn(address(uint160(44100)), address(uint160(44200)), recoveringArbiter);
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(recoveringArbiter), 1);

        // A correctly finalized verdict resets the streak back to 0.
        address cli2 = address(uint160(44300));
        usdc.mint(cli2, 1_000_000 * 10**6);
        vm.prank(cli2);
        usdc.approve(address(diamond), 10 * 10**6);
        address exec2 = address(uint160(44400));
        vm.prank(address(diamond));
        address agreement2 = FactoryFacet(address(diamond)).deployAgreement(
            cli2, exec2, recoveringArbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli2);
        usdc.approve(agreement2, AMOUNT);
        vm.prank(cli2);
        Agreement(agreement2).fund();
        vm.prank(exec2);
        Agreement(agreement2).activate();
        vm.prank(cli2);
        Agreement(agreement2).raiseDispute();
        _claimDisputeAs(agreement2, recoveringArbiter);
        vm.prank(recoveringArbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreement2, true);
        vm.warp(block.timestamp + 72 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreement2);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(recoveringArbiter), 0);
        assertTrue(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(recoveringArbiter));
    }

    // ============ AGREEMENT TIMEOUT INTEGRATION ============

    function testActivationTimeoutResetsExecutorStreak() public {
        _warmUpClientXP(client);
        address freshExecutor = address(uint160(50001));
        _completeDeal(client, freshExecutor);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);

        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, freshExecutor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();

        vm.warp(block.timestamp + 6 days); // > ACTIVATION_WINDOW, executor never activated
        vm.prank(client);
        Agreement(agreementAddr).triggerActivationTimeout();

        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 0);
    }

    function testDeadlineTimeoutResetsExecutorStreak() public {
        _warmUpClientXP(client);
        address freshExecutor = address(uint160(50002));
        _completeDeal(client, freshExecutor);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);

        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, freshExecutor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        vm.prank(freshExecutor);
        Agreement(agreementAddr).activate();

        vm.warp(block.timestamp + (DEADLINE * 1 days) + 2 days); // past deadline + grace, never marked done
        vm.prank(client);
        Agreement(agreementAddr).triggerDeadlineTimeout();

        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 0);
    }

    function testArbiterTimeoutDoesNotTouchExecutorStreakButCountsAgainstArbiter() public {
        _warmUpClientXP(client);
        address freshExecutor = address(uint160(50003));
        _completeDeal(client, freshExecutor);
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);

        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, freshExecutor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        vm.prank(freshExecutor);
        Agreement(agreementAddr).activate();
        vm.prank(client);
        Agreement(agreementAddr).raiseDispute();
        _claimDispute(agreementAddr);

        vm.warp(block.timestamp + 8 days); // > DISPUTE_WINDOW, arbiter never submitted a verdict
        vm.prank(client);
        Agreement(agreementAddr).triggerArbiterTimeout();

        // Executor's streak is untouched — the arbiter, not the executor, failed here.
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(freshExecutor), 1);
        // The arbiter's mistake streak did register the failure.
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1);
    }

    // Full deploy -> fund -> activate -> dispute -> claim -> (arbiter never responds) ->
    // triggerArbiterTimeout cycle against a single fresh counterparty pair. Kept as its own
    // function for the same reason as _disputeAndOverturn (see its comment) — no `for` loop.
    function _disputeAndArbiterTimeout(address cli, address exec, address arbiterAddr, uint256 warpTo) internal {
        usdc.mint(cli, 1_000_000 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, exec, arbiterAddr, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(exec);
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDisputeAs(agreementAddr, arbiterAddr);

        // Absolute target, not block.timestamp + N: computing the warp target from a live
        // block.timestamp read was observed to silently no-op on the second+ call to this
        // helper within one test (same class of issue noted on _claimDisputeAs's vm.roll).
        // warpTo is always well past disputedAt + DISPUTE_WINDOW (4 days) as long as callers
        // space their warpTo values generously (see call sites).
        vm.warp(warpTo);
        vm.prank(cli);
        Agreement(agreementAddr).triggerArbiterTimeout();
    }

    function testThreeArbiterTimeoutsDemoteTheArbiter() public {
        address flakyArbiter = address(uint160(51000));
        ArbiterRegistryFacet(address(diamond)).addArbiter(flakyArbiter);
        _bondSeat(flakyArbiter);

        _disputeAndArbiterTimeout(address(uint160(51100)), address(uint160(51200)), flakyArbiter, 10_000_000);
        _disputeAndArbiterTimeout(address(uint160(51101)), address(uint160(51201)), flakyArbiter, 20_000_000);
        _disputeAndArbiterTimeout(address(uint160(51102)), address(uint160(51202)), flakyArbiter, 30_000_000);

        // ⚠️ The third timeout accuses; removal goes through the common door.
        // It is separately valuable that the timeout path GOT THERE at all:
        // Agreement calls notifyArbiterTimeout inside an EMPTY try/catch, and a
        // revert in the new branch would have been swallowed in silence — "not
        // punished" would have looked exactly like "punished".
        assertTrue(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(flakyArbiter));

        // ⚠️ TURNED OVER ON 21 SEPTEMBER 2026: this line read
        // `assertEq(getXP(flakyArbiter), 2500)`, the flat landing point the
        // accusation used to write. The reset is gone. On THIS path the record is
        // doubly untouched — notifyArbiterTimeout deliberately slashes nothing
        // either (there was no ruling to overturn) — so a zero here is the whole
        // statement: three timeouts stop the man and accuse him, and write not one
        // point into what he earned as a worker.
        assertEq(
            ReputationFacet(address(diamond)).getXP(flakyArbiter), 0,
            "a timeout neither slashes nor resets the record of work"
        );

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(address(uint160(51999)));
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(flakyArbiter);

        assertFalse(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));
    }

    function testAgreementRevertIfNotClientFund() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(executor);
        vm.expectRevert(Agreement.NotClient.selector);
        Agreement(agreementAddr).fund();
    }
    
    function testAgreementRevertIfAlreadyFunded() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(client);
        vm.expectRevert(Agreement.AlreadyFunded.selector);
        Agreement(agreementAddr).fund();
    }
    
    function testAgreementRevertIfNotExecutorActivate() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(client);
        vm.expectRevert(Agreement.NotExecutor.selector);
        Agreement(agreementAddr).activate();
    }
    
    function testAgreementRevertIfActivationWindowPassed() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.warp(block.timestamp + 4 days);
        
        vm.prank(executor);
        vm.expectRevert(Agreement.ActivationWindowPassed.selector);
        Agreement(agreementAddr).activate();
    }
    
    function testAgreementRevertIfNotActiveMarkDone() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(executor);
        vm.expectRevert(Agreement.NotActive.selector);
        Agreement(agreementAddr).markDone();
    }
    
    function testAgreementRevertIfAlreadyMarkedDone() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(executor);
        Agreement(agreementAddr).activate();
        vm.prank(executor);
        Agreement(agreementAddr).markDone();
        
        vm.prank(executor);
        vm.expectRevert(Agreement.AlreadyMarkedDone.selector);
        Agreement(agreementAddr).markDone();
    }
    
    function testAgreementRevertIfNotMarkedDoneRelease() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(executor);
        Agreement(agreementAddr).activate();
        
        vm.prank(client);
        vm.expectRevert(Agreement.NotMarkedDone.selector);
        Agreement(agreementAddr).release();
    }
    
    function testAgreementRevertIfDisputedRelease() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(executor);
        Agreement(agreementAddr).activate();
        
        // Raise dispute BEFORE markDone (can't dispute after markDone per contract)
        vm.prank(client);
        Agreement(agreementAddr).raiseDispute();
        
        // Now try to release - should revert because not marked done
        vm.prank(client);
        vm.expectRevert(Agreement.NotMarkedDone.selector);
        Agreement(agreementAddr).release();
    }
    
    function testAgreementAutoApprove() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(executor);
        Agreement(agreementAddr).activate();
        vm.prank(executor);
        Agreement(agreementAddr).markDone();
        
        vm.warp(block.timestamp + 6 days);
        
        uint256 executorBalanceBefore = usdc.balanceOf(executor);
        vm.prank(executor);
        Agreement(agreementAddr).triggerAutoApprove();
        
        assertEq(usdc.balanceOf(executor), executorBalanceBefore + AMOUNT);
    }
    
    function testAgreementDisputeAndResolve() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );

        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();

        vm.prank(executor);
        Agreement(agreementAddr).activate();

        vm.prank(client);
        Agreement(agreementAddr).raiseDispute();

        assertEq(uint256(Agreement(agreementAddr).status()), uint256(Agreement.Status.DISPUTED));

        _claimDispute(agreementAddr);

        uint256 clientBalanceBefore = usdc.balanceOf(client);
        _resolveDispute(agreementAddr, true);

        assertEq(uint256(Agreement(agreementAddr).status()), uint256(Agreement.Status.RESOLVED));
        assertEq(usdc.balanceOf(client), clientBalanceBefore + AMOUNT);
    }
    
    function testAgreementDisputeResolveExecutorWins() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );

        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();

        vm.prank(executor);
        Agreement(agreementAddr).activate();

        vm.prank(executor);
        Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);

        uint256 executorBalanceBefore = usdc.balanceOf(executor);
        _resolveDispute(agreementAddr, false);

        assertEq(usdc.balanceOf(executor), executorBalanceBefore + AMOUNT);
    }

    // Winner of a resolved dispute earns XP; loser earns none (baseline, no prior XP).
    function testAutoAwardXPWinnerOnlyOnResolved() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );

        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();

        vm.prank(executor);
        Agreement(agreementAddr).activate();

        vm.prank(client);
        Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);
        _resolveDispute(agreementAddr, true); // client wins — executor loses

        assertTrue(ReputationFacet(address(diamond)).getXP(client) > 0);
        assertEq(ReputationFacet(address(diamond)).getXP(executor), 0);
    }

    // A dispute loss must actually subtract XP the loser already earned from a prior
    // completed deal — not just withhold new XP. Regression guard for the exploit where
    // losing a dispute cost nothing, letting a bad-faith executor farm reputation for free.
    function testAutoAwardXPPenalizesDisputeLoser() public {
        // Deal 1: honest completion — both sides earn XP (100 win + 10 volume = 110).
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address deal1 = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client);
        usdc.approve(deal1, AMOUNT);
        vm.prank(client);
        Agreement(deal1).fund();
        vm.prank(executor);
        Agreement(deal1).activate();
        vm.prank(executor);
        Agreement(deal1).markDone();
        vm.prank(client);
        Agreement(deal1).release();

        uint256 executorXPAfterDeal1 = ReputationFacet(address(diamond)).getXP(executor);
        assertEq(executorXPAfterDeal1, 110);

        // Deal 2: same pair, disputed — client wins, executor loses.
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address deal2 = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client);
        usdc.approve(deal2, AMOUNT);
        vm.prank(client);
        Agreement(deal2).fund();
        vm.prank(executor);
        Agreement(deal2).activate();
        vm.prank(client);
        Agreement(deal2).raiseDispute();
        _claimDispute(deal2);
        _resolveDispute(deal2, true); // client wins — executor loses

        // Executor loses 50 XP (half of WIN_XP) off their deal-1 balance.
        assertEq(ReputationFacet(address(diamond)).getXP(executor), executorXPAfterDeal1 - 50);
    }

    function testAgreementRevertIfNotArbiterResolve() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );

        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();

        vm.prank(executor);
        Agreement(agreementAddr).activate();

        vm.prank(client);
        Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);

        vm.prank(client);
        vm.expectRevert(Agreement.NotArbiter.selector);
        Agreement(agreementAddr).resolveDispute(true);
    }
    
    function testAgreementRevertIfNoArbiterSet() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, address(0), AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(executor);
        Agreement(agreementAddr).activate();
        
        vm.prank(client);
        Agreement(agreementAddr).raiseDispute();
        
        vm.prank(arbiter);
        vm.expectRevert(Agreement.NoArbiterSet.selector);
        Agreement(agreementAddr).resolveDispute(true);
    }
    
    function testAgreementActivationTimeout() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.warp(block.timestamp + 4 days);
        
        uint256 clientBalanceBefore = usdc.balanceOf(client);
        vm.prank(client);
        Agreement(agreementAddr).triggerActivationTimeout();
        
        // After triggerActivationTimeout, NFT is burned so status() returns based on timers
        assertEq(usdc.balanceOf(client), clientBalanceBefore + AMOUNT);
    }
    
    function testAgreementDeadlineTimeout() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, 1, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(executor);
        Agreement(agreementAddr).activate();
        
        vm.warp(block.timestamp + 2 days + 1); // DEADLINE(1d) + DEADLINE_GRACE(1d) + 1sec

        uint256 clientBalanceBefore = usdc.balanceOf(client);
        vm.prank(client);
        Agreement(agreementAddr).triggerDeadlineTimeout();
        
        assertEq(uint256(Agreement(agreementAddr).status()), uint256(Agreement.Status.REFUNDED));
        assertEq(usdc.balanceOf(client), clientBalanceBefore + AMOUNT);
    }
    
    function testAgreementArbiterTimeout() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(executor);
        Agreement(agreementAddr).activate();

        // The work is handed in first: since 25 September 2026 the unclaimed-timeout
        // branch reads delivery before attendance, and without a markDone the whole
        // escrow goes back to the client (DisputeSettlement holds that scene).
        vm.prank(executor);
        Agreement(agreementAddr).markDone();

        vm.prank(client);
        Agreement(agreementAddr).raiseDispute();
        // The other side responded: halves now mean "both showed up".
        vm.prank(executor);
        Agreement(agreementAddr).respondToDispute();

        vm.warp(block.timestamp + 8 days);

        uint256 clientBalanceBefore   = usdc.balanceOf(client);
        uint256 executorBalanceBefore = usdc.balanceOf(executor);
        vm.prank(client);
        Agreement(agreementAddr).triggerArbiterTimeout();

        // Nobody took this dispute on (claimDispute is not called here, and the
        // agreement's arbiter field stayed zero), so the pot is split in half rather
        // than returned to the client whole: a full refund would make an empty
        // dispute a free way to take back both the money and the work. The branch
        // "an arbiter took it on and did not finish" — where the client still gets
        // everything — is held by
        // testTimeoutAfterClaimStillRefundsTheClient in the DisputeSettlement suite.
        assertEq(usdc.balanceOf(client),   clientBalanceBefore   + AMOUNT / 2, "half back to the client");
        assertEq(usdc.balanceOf(executor), executorBalanceBefore + AMOUNT / 2, "half to the executor");
        assertEq(usdc.balanceOf(agreementAddr), 0, "the agreement must be emptied");
    }
    
    function testAgreementSoulbound() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(client);
        vm.expectRevert(bytes4(keccak256("TokenSoulbound()")));
        Agreement(agreementAddr).transferFrom(client, address(0x5), 1);
    }
    
    // ============ FUZZ TESTS ============
    
    function testFuzzDeployAgreement(uint64 amount, uint64 deadline) public {
        amount = uint64(bound(amount, 1 * 10**6, 100000 * 10**6));
        deadline = uint64(bound(deadline, 1, 365));

        // Fee is a percentage of the fuzzed amount now, not a flat regional
        // cap — a fixed 10 USDC approval no longer covers every fuzzed value.
        uint256 fee = (uint256(amount) * 500) / 10_000;
        if (fee < 1_000_000) fee = 1_000_000;

        vm.prank(client);
        usdc.approve(address(diamond), fee);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, amount, deadline, TERMS_HASH, 0
        );
        
        assertTrue(agreementAddr != address(0));
        assertEq(Agreement(agreementAddr).amount(), amount);
        assertEq(Agreement(agreementAddr).deadlineDays(), deadline);
    }
    
    function testFuzzAgreementStatus(uint64 timeJump) public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        
        vm.prank(client);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client);
        Agreement(agreementAddr).fund();
        
        vm.prank(executor);
        Agreement(agreementAddr).activate();
        
        timeJump = uint64(bound(timeJump, 0, 30 days));
        vm.warp(block.timestamp + timeJump);
        
        uint256 s = uint256(Agreement(agreementAddr).status());
        assertLe(s, 6);
    }

    // ============ ARBITER REGISTRY TESTS ============

    function testArbiterRegistryAddArbiter() public {
        address newArbiter = address(0x10);
        ArbiterRegistryFacet(address(diamond)).addArbiter(newArbiter);
        _bondSeat(newArbiter);
        assertTrue(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(newArbiter));
        address[] memory list = ArbiterVaultFacet(address(diamond)).getArbiters();
        assertEq(list.length, 2); // arbiter from setUp + new
    }

    function testArbiterRegistryAddRevertIfAlreadyArbiter() public {
        vm.expectRevert(ArbiterRegistryFacet.AlreadyArbiter.selector);
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
        _bondSeat(arbiter);
    }

    function testArbiterRegistryAddRevertIfNotOwner() public {
        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.NotOwner.selector);
        ArbiterRegistryFacet(address(diamond)).addArbiter(address(0x10));
    }

    // testArbiterRegistryRemoveArbiter / testArbiterRegistryRemoveRevertIfNotArbiter
    // were deleted on 15 August 2026: removeArbiter was taken off the facet
    // entirely, and its replacement is
    // ArbiterAccountabilityFacet.removeArbiterForCause (the ArbiterRemovalForCause
    // suite).

    /// ⚠️ THE CHIEF LOST THIS DOOR ON 22 SEPTEMBER 2026 and this scene was
    /// turned round. It used to assert that he could seat. The owner's
    /// decision: `addArbiter` asks for no record at all, which makes it the
    /// widest hole in the corps, and it was held by a man who had himself been
    /// appointed. Everything else the chief has — proposing a removal,
    /// suspending, answering — is untouched.
    function testArbiterRegistryChiefCannotAdd() public {
        address chief = address(0x20);
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(chief);
        assertEq(ArbiterVaultFacet(address(diamond)).getChiefArbiter(), chief);

        vm.prank(chief);
        vm.expectRevert(ArbiterRegistryFacet.NotOwner.selector);
        ArbiterRegistryFacet(address(diamond)).addArbiter(address(0x21));
        assertFalse(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(address(0x21)));

        // And the owner's press on the same man goes through, so the refusal is
        // about who pressed and not about the man.
        ArbiterRegistryFacet(address(diamond)).addArbiter(address(0x21));
        assertTrue(ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(address(0x21)));
    }

    function testArbiterCommitRevertIfNotRegistered() public {
        bytes32 commitment = keccak256(abi.encodePacked(address(0x100), client, DISPUTE_SALT));
        vm.prank(client); // not a registered arbiter
        vm.expectRevert(ArbiterRegistryFacet.NotArbiter.selector);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
    }

    function testArbiterClaimRevertIfCommitTooEarly() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();

        bytes32 commitment = keccak256(abi.encodePacked(agreementAddr, arbiter, DISPUTE_SALT));
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);

        // Reveal in the same block — should fail
        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.CommitmentTooEarly.selector);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agreementAddr, DISPUTE_SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function testArbiterClaimRevertIfCommitmentExpired() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();

        bytes32 commitment = keccak256(abi.encodePacked(agreementAddr, arbiter, DISPUTE_SALT));
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);

        vm.roll(block.number + 51); // past COMMIT_MAX_BLOCKS (50)

        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.CommitmentExpired.selector);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agreementAddr, DISPUTE_SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function testArbiterClaimRevertIfNotDisputed() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        // No raiseDispute — agreement is ACTIVE, not DISPUTED

        bytes32 commitment = keccak256(abi.encodePacked(agreementAddr, arbiter, DISPUTE_SALT));
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);

        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.NotDisputed.selector);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agreementAddr, DISPUTE_SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function testArbiterClaimRevertIfAlreadyClaimed() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);

        // Second arbiter tries to claim the same dispute
        address arbiter2 = address(0x30);
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter2);
        _bondSeat(arbiter2);
        bytes32 commitment2 = keccak256(abi.encodePacked(agreementAddr, arbiter2, DISPUTE_SALT));
        vm.prank(arbiter2);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment2);
        vm.roll(block.number + 1);

        vm.prank(arbiter2);
        vm.expectRevert(ArbiterRegistryFacet.AlreadyClaimed.selector);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agreementAddr, DISPUTE_SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    function testArbiterReleaseDisputeClaim() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);

        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeClaimer(agreementAddr), arbiter);
        // After claimDispute the Diamond (not the individual arbiter) becomes the Agreement's arbiter
        assertEq(Agreement(agreementAddr).arbiter(), address(diamond));

        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(agreementAddr);

        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeClaimer(agreementAddr), address(0));
        assertEq(Agreement(agreementAddr).arbiter(), address(0));
    }

    function testArbiterOwnerCanReleaseClaim() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);

        // Owner (address(this)) releases — not the arbiter
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(agreementAddr);
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeClaimer(agreementAddr), address(0));
    }

    function testArbiterDealsHistoryTracked() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);

        address[] memory deals = ArbiterAccountabilityFacet(address(diamond)).getArbiterDeals(arbiter);
        assertEq(deals.length, 1);
        assertEq(deals[0], agreementAddr);
    }

    // ============ AGREEMENT EDGE CASES ============

    function testAgreementRaiseDisputeByExecutor() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();

        // The executor can raise a dispute too
        vm.prank(executor);
        Agreement(agreementAddr).raiseDispute();

        assertEq(uint256(Agreement(agreementAddr).status()), uint256(Agreement.Status.DISPUTED));
    }

    function testAgreementRevertIfAlreadyDisputed() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();

        vm.prank(executor);
        vm.expectRevert(Agreement.AlreadyDisputed.selector);
        Agreement(agreementAddr).raiseDispute();
    }

    function testAgreementRaiseDisputeAfterMarkDone() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(executor); Agreement(agreementAddr).markDone();

        // The client can raise a dispute after markDone, if AUTO_APPROVE_WINDOW has not passed
        vm.prank(client);
        Agreement(agreementAddr).raiseDispute();

        assertEq(uint256(Agreement(agreementAddr).status()), uint256(Agreement.Status.DISPUTED));
    }

    function testAgreementRaiseDisputeRevertAfterDeadline() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, 1, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();

        vm.warp(block.timestamp + 2 days + 1); // DEADLINE(1d) + DEADLINE_GRACE(1d) + 1sec

        vm.prank(client);
        vm.expectRevert(Agreement.DeadlinePassed.selector);
        Agreement(agreementAddr).raiseDispute();
    }

    function testAgreementReleaseRevertIfWindowPassed() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(executor); Agreement(agreementAddr).markDone();

        vm.warp(block.timestamp + 6 days); // AUTO_APPROVE_WINDOW = 5 days

        vm.prank(client);
        vm.expectRevert(Agreement.WindowAlreadyPassed.selector);
        Agreement(agreementAddr).release();
    }

    function testAgreementAutoApproveRevertIfWindowNotPassed() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(executor); Agreement(agreementAddr).markDone();

        // Too early — the window has not passed yet
        vm.prank(address(0x99));
        vm.expectRevert(Agreement.WindowNotPassed.selector);
        Agreement(agreementAddr).triggerAutoApprove();
    }

    function testAgreementAutoApproveByAnyone() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(executor); Agreement(agreementAddr).markDone();

        vm.warp(block.timestamp + 6 days);

        uint256 executorBefore = usdc.balanceOf(executor);
        address stranger = address(0xBEEF);
        vm.prank(stranger); // neither client nor executor
        Agreement(agreementAddr).triggerAutoApprove();

        assertEq(usdc.balanceOf(executor), executorBefore + AMOUNT);
    }

    function testAgreementActivationTimeoutTooEarly() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();

        // ACTIVATION_WINDOW = 3 days, 2 days passed — too early
        vm.warp(block.timestamp + 2 days);

        vm.prank(client);
        vm.expectRevert(Agreement.WindowNotPassed.selector);
        Agreement(agreementAddr).triggerActivationTimeout();
    }

    function testAgreementDeadlineTimeoutTooEarly() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, 7, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();

        // Deadline = 7 days, 5 days passed — too early
        vm.warp(block.timestamp + 5 days);

        vm.prank(client);
        vm.expectRevert(Agreement.DeadlineNotPassed.selector);
        Agreement(agreementAddr).triggerDeadlineTimeout();
    }

    function testAgreementArbiterTimeoutTooEarly() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();

        // DISPUTE_WINDOW = 4 days, 3 days passed — too early
        vm.warp(block.timestamp + 3 days);

        vm.prank(client);
        vm.expectRevert(Agreement.WindowNotPassed.selector);
        Agreement(agreementAddr).triggerArbiterTimeout();
    }

    function testSubmitVerdict_RevertsAfterDisputeWindow() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client);
        usdc.approve(agr, AMOUNT);
        vm.prank(client);
        Agreement(agr).fund();
        vm.prank(executor);
        Agreement(agr).activate();
        vm.prank(client);
        Agreement(agr).raiseDispute();

        _claimDispute(agr);

        // DISPUTE_WINDOW is 4 days — warp past it before the arbiter ever submits.
        vm.warp(block.timestamp + 4 days + 1);

        vm.prank(arbiter);
        vm.expectRevert(ArbiterRegistryFacet.DisputeWindowPassed.selector);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agr, true);
    }

    function testTriggerArbiterTimeout_RevertsIfVerdictAlreadySubmitted() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client);
        usdc.approve(agr, AMOUNT);
        vm.prank(client);
        Agreement(agr).fund();
        vm.prank(executor);
        Agreement(agr).activate();
        vm.prank(client);
        Agreement(agr).raiseDispute();

        _claimDispute(agr);

        // Arbiter submits promptly (well within DISPUTE_WINDOW).
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agr, true);

        // Time still passes disputedAt + DISPUTE_WINDOW while FINALIZE_DELAY/appeal run.
        vm.warp(block.timestamp + 4 days + 1);

        vm.prank(client);
        vm.expectRevert(Agreement.VerdictInFlight.selector);
        Agreement(agr).triggerArbiterTimeout();

        // And finalization still succeeds — the removed execution-time check isn't missed.
        vm.warp(block.timestamp + 72 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        assertEq(uint8(Agreement(agr).status()), uint8(Agreement.Status.RESOLVED));
    }

    function testAgreementMarkDoneRevertAfterDeadline() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, 1, TERMS_HASH, 0 // deadline = 1 day
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();

        vm.warp(block.timestamp + 2 days + 1); // DEADLINE(1d) + DEADLINE_GRACE(1d) + 1sec

        vm.prank(executor);
        vm.expectRevert(Agreement.DeadlinePassed.selector);
        Agreement(agreementAddr).markDone();
    }

    function testAgreementRevertIfAlreadyResolved() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();
        _claimDispute(agreementAddr);
        _resolveDispute(agreementAddr, true);

        // A repeated finalizeVerdict must revert AlreadyFinalized
        vm.expectRevert(ArbiterRegistryFacet.AlreadyFinalized.selector);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);
    }

    function testRegistrySetAuthorizedFactory() public {
        address newFactory = address(0x50);
        // owner = address(this) in the tests
        RegistryFacet(address(diamond)).setAuthorizedFactory(newFactory);
        assertEq(RegistryFacet(address(diamond)).authorizedFactory(), newFactory);
    }

    function testRegistrySetAuthorizedFactoryRevertIfNotOwner() public {
        vm.prank(client);
        vm.expectRevert(RegistryFacet.NotOwner.selector);
        RegistryFacet(address(diamond)).setAuthorizedFactory(address(0x50));
    }

    function testArbiterClaimClearedAfterResolve() public {
        vm.prank(client);
        usdc.approve(address(diamond), 10 * 10**6);
        vm.prank(address(diamond));
        address agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            client, executor, arbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(client); usdc.approve(agreementAddr, AMOUNT);
        vm.prank(client); Agreement(agreementAddr).fund();
        vm.prank(executor); Agreement(agreementAddr).activate();
        vm.prank(client); Agreement(agreementAddr).raiseDispute();

        _claimDispute(agreementAddr);

        _resolveDispute(agreementAddr, true);

        // After resolution, the claim should be cleared by Agreement's callback
        assertEq(ArbiterVaultFacet(address(diamond)).getDisputeClaimer(agreementAddr), address(0));
    }

    function testRaiseAppeal_LosingExecutorCanAppeal() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // client wins, executor loses

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);

        uint256 diamondBalBefore = usdc.balanceOf(address(diamond));
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)
        assertEq(usdc.balanceOf(address(diamond)), diamondBalBefore + 20 * 10**6);

        // Frozen — finalizeVerdict can't proceed until the appeal resolves.
        vm.warp(block.timestamp + 72 hours + 1);
        vm.expectRevert(ArbiterRegistryFacet.VerdictFrozenError.selector);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
    }

    function testRaiseAppeal_RevertsForWinningParty() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // client wins

        usdc.mint(client, 100 * 10**6);
        vm.prank(client);
        usdc.approve(address(diamond), 20 * 10**6);

        vm.prank(client); // client already won — not the losing party
        vm.expectRevert(ArbiterRegistryFacet.NotLosingParty.selector);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
    }

    function testRaiseAppeal_RevertsIfAlreadyAppealed() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 40 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        vm.prank(executor);
        vm.expectRevert(ArbiterRegistryFacet.AlreadyAppealed.selector);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
    }

    function testRaiseAppeal_RevertsAfterWindowCloses() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);

        vm.warp(block.timestamp + 72 hours + 1);
        vm.prank(executor);
        vm.expectRevert(ArbiterRegistryFacet.AppealWindowClosed.selector);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
    }

    /// ⚠️ THE DOOR STOPPED COUNTING ON 23 SEPTEMBER 2026, so this scene asks
    /// the opposite question to the one it used to ask. It was
    /// `testRaiseAppeal_RevertsWithTooFewArbiters`: the only arbiter is the one
    /// who ruled, nobody may review the case, and `raiseAppeal` refused with
    /// `InsufficientArbitersForAppeal`. Answering that needed a walk over the
    /// whole roster, paid for by the appellant, growing with a corps that has
    /// no ceiling. The appeal is now let in and the question is answered at the
    /// end of the review window instead — where a panel that never assembled
    /// costs the appellant nothing (test/AppealPanel.t.sol holds the refund).
    function testRaiseAppeal_IsLetInEvenWithNobodyToHearIt() public {
        // No extra arbiters registered — only the default `arbiter` exists, and
        // he is the one whose verdict is being challenged.
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);

        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        assertTrue(
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr).appealed,
            "the door refused an appeal it no longer has the means to judge"
        );
    }

    /// Puts a verdict into the state a HAND left behind: `frozen = true` with no
    /// appeal attached to it.
    ///
    /// ⚠️ WHY `vm.store` AND NOT A CALL. `freezeVerdict` is gone (9 October
    /// 2026) and nothing writes `frozen` any more except `raiseAppeal` -- which
    /// sets `appealed` in the same breath, so it cannot build "frozen, never
    /// appealed" at all. The state is still REAL: verdicts a hand froze before
    /// the cut are on chain with exactly these bits, and `FREEZE_WINDOW` plus
    /// `_freezeHolds` were deliberately kept for them. So this is a legacy
    /// state, reached the only way left.
    ///
    /// ⚠️ THE OFFSET IS WITNESSED, NOT TRUSTED. `pendingVerdicts` is field 6 of
    /// ArbiterRegistryStorage.Data and `frozen` is the lowest byte of the
    /// record's THIRD slot, packed with five more bools and `appellant`. The
    /// word is read and OR-ed rather than overwritten, so a drifted offset
    /// cannot silently clear a neighbour; the getter is then asked whether the
    /// bit actually landed, and the neighbours are asked whether they stayed
    /// put. The same rig, and the same reason for it, as
    /// testAFreezeFromBeforeTheFieldExistedLapsesFromTheSubmission in
    /// test/DisputeSettlement.t.sol.
    function _freezeAsAHandDidBeforeTheCut(address agr) internal {
        bytes32 flagSlot = bytes32(
            uint256(keccak256(abi.encode(agr, uint256(ArbiterRegistryStorage.POSITION) + 6))) + 2
        );
        bytes32 word = vm.load(address(diamond), flagSlot);
        vm.store(address(diamond), flagSlot, word | bytes32(uint256(1)));

        ArbiterRegistryStorage.PendingVerdict memory w =
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr);
        assertTrue(w.frozen, "the frozen offset missed - this helper is poking an unrelated slot");
        assertFalse(w.finalized, "the write landed on a neighbour (finalized)");
        assertFalse(w.appealed, "the write landed on a neighbour (appealed)");
        assertGt(w.submittedAt, 0, "the record itself was not found");
    }

    /// ⚠️ THE DOOR THIS WAS NAMED AFTER IS GONE, THE CHECK IT GUARDS IS NOT.
    /// `freezeVerdict` was removed on 9 October 2026, and the obvious reading is
    /// that this scene went with it. It did not: `raiseAppeal` still carries
    /// `if (v.frozen) revert VerdictFrozenError()`, and that line stays
    /// REACHABLE for every verdict a hand froze before the cut and that is still
    /// sitting on chain unfinalized. Delete the scene and the last thing
    /// standing over that line goes quiet, for a state the chain really holds.
    /// So the freeze is built where it now comes from -- the past -- and the
    /// refusal is asserted exactly as before.
    function testRaiseAppeal_RevertsIfOwnerFrozeBeforeAnyAppeal() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // client wins, executor loses

        // A verdict frozen by a hand before the cut, still waiting (see the helper).
        _freezeAsAHandDidBeforeTheCut(agr);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);

        vm.prank(executor);
        vm.expectRevert(ArbiterRegistryFacet.VerdictFrozenError.selector);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        ArbiterRegistryStorage.PendingVerdict memory v = ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr);
        assertFalse(v.appealed);
    }

    function testVoteOnAppeal_ArbiterCanVoteOnce() public {
        (address a2,,) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        ArbiterRegistryStorage.PendingVerdict memory before = ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr);
        assertEq(before.votesOverturn, 0);
        assertEq(before.votesUphold, 0);

        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterRegistryFacet.AppealVoteCast(agr, a2, true);
        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);

        // Successful vote incremented the right tally (overturn) and left the other untouched.
        ArbiterRegistryStorage.PendingVerdict memory afterVote = ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr);
        assertEq(afterVote.votesOverturn, 1);
        assertEq(afterVote.votesUphold, 0);

        vm.prank(a2);
        vm.expectRevert(ArbiterRegistryFacet.AlreadyVoted.selector);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);

        // Repeat-vote revert must not have double-counted.
        ArbiterRegistryStorage.PendingVerdict memory afterRevert = ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr);
        assertEq(afterRevert.votesOverturn, 1);
        assertEq(afterRevert.votesUphold, 0);
    }

    function testVoteOnAppeal_DifferentArbitersCanEachVoteOnce() public {
        (address a2, address a3,) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterRegistryFacet.AppealVoteCast(agr, a2, true);
        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // a2 votes to overturn

        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterRegistryFacet.AppealVoteCast(agr, a3, false);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // a3 votes to uphold — different arbiter, no revert

        // Both votes recorded distinctly in the tally.
        ArbiterRegistryStorage.PendingVerdict memory v = ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr);
        assertEq(v.votesOverturn, 1);
        assertEq(v.votesUphold, 1);

        // a3 can't vote again either, but a2's earlier vote didn't block a3 in the first place.
        vm.prank(a3);
        vm.expectRevert(ArbiterRegistryFacet.AlreadyVoted.selector);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
    }

    function testVoteOnAppeal_RulingArbiterCannotVoteOnOwnVerdict() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        vm.prank(arbiter); // the one who ruled
        vm.expectRevert(ArbiterRegistryFacet.CannotVoteOnOwnVerdict.selector);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
    }

    function testVoteOnAppeal_RevertsWithoutAppeal() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        vm.prank(address(0x30));
        vm.expectRevert(ArbiterRegistryFacet.NoAppeal.selector);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
    }

    function testVoteOnAppeal_RevertsAfterWindowCloses() public {
        (address a2,,) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        vm.warp(block.timestamp + 4 days + 1); // APPEAL_REVIEW_WINDOW

        vm.prank(a2);
        vm.expectRevert(ArbiterRegistryFacet.AppealWindowClosed.selector);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
    }

    function testResolveAppeal_OverturnFlipsVerdictAndPenalizesArbiter() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // client wins, executor loses

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        uint256 executorBalBefore = usdc.balanceOf(executor);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        // Deposit refunded to the appellant (executor).
        assertEq(usdc.balanceOf(executor), executorBalBefore - 20 * 10**6 + 20 * 10**6);
        // Ruling arbiter penalized exactly like today's overturnVerdict.
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1);

        // Verdict flipped — finalizing now pays the executor, not the client.
        vm.warp(block.timestamp + 72 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        assertEq(usdc.balanceOf(executor), executorBalBefore - 20 * 10**6 + 20 * 10**6 + AMOUNT);
    }

    // ============================================================
    //  A DEPOSIT THAT CANNOT BE DELIVERED MUST NOT LOCK THE ESCROW (31 August 2026)
    //
    //  resolveAppeal used to end a WON appeal with a hard push:
    //      bool refundOk = IUSDCFull(usdc).transfer(v.appellant, _depositOf(v));
    //      require(refundOk, "ArbiterRegistry: deposit refund failed");
    //  USDC can refuse — a blacklisted address is the ordinary way. The refund
    //  stands AFTER `appealResolved = true; frozen = false;`, so its revert took
    //  those two writes down with it, and every other door out is shut:
    //  finalizeVerdict → VerdictFrozenError, unfreezeVerdict/overturnVerdict →
    //  AppealInProgress, raiseAppeal → AlreadyAppealed, and the Agreement's own
    //  last exit, triggerArbiterTimeout, → VerdictInFlight forever, because
    //  hasSubmittedVerdict is `submittedAt != 0` and never goes back.
    //
    //  So a $20 deposit stranded the WHOLE escrow inside the clone, where no
    //  rescue function exists — and it stranded it for the man who WON.
    //
    //  ⚠️ THE ORACLE IS THE TOKEN, NOT US. What "refuse" means is taken from how
    //  USDC behaves — `false`, and separately a reply too short to decode — and
    //  fed in with vm.mockCall, the same device SafeUSDC.trySafeTransfer is
    //  tested with in DisputeSettlement.t.sol. Nothing here asks our own
    //  function what failure looks like.
    // ============================================================

    /// The appellant won and cannot be paid. The escrow must still open.
    function test_AWonAppealOpensTheEscrowEvenIfTheDepositCannotBeDelivered() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // executor loses, appeals

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)
        uint256 balAfterPaying = usdc.balanceOf(executor);

        _voteOverturn(agr, a2, a3, a4);

        // The token refuses this exact refund, and only it.
        vm.mockCall(
            address(usdc),
            abi.encodeWithSelector(bytes4(0xa9059cbb), executor, uint256(20 * 10**6)),
            abi.encode(false)
        );
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);
        vm.clearMockedCalls();

        // The deposit did NOT reach his wallet — that is the premise, not the bug.
        assertEq(usdc.balanceOf(executor), balAfterPaying, "deposit should not have landed");

        // The bug would be here: the verdict is unfrozen and the escrow pays out.
        vm.warp(block.timestamp + 72 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        assertEq(
            usdc.balanceOf(executor),
            balAfterPaying + AMOUNT,
            "the escrow stayed locked for the man who won the appeal"
        );
    }

    /// And the money that could not be pushed is not lost — it is claimable.
    function test_TheUndeliveredAppealDepositIsClaimableNotLost() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)
        uint256 balAfterPaying = usdc.balanceOf(executor);

        _voteOverturn(agr, a2, a3, a4);

        vm.mockCall(
            address(usdc),
            abi.encodeWithSelector(bytes4(0xa9059cbb), executor, uint256(20 * 10**6)),
            abi.encode(false)
        );
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);
        vm.clearMockedCalls();

        // It landed in the claimable, whole.
        assertEq(
            ArbiterVaultFacet(address(diamond)).getRefundableBounty(executor),
            20 * 10**6,
            "the undelivered deposit was written down nowhere"
        );

        // And the existing button really pays it out.
        vm.prank(executor);
        ArbiterVaultFacet(address(diamond)).withdrawDisputeBounty();
        assertEq(usdc.balanceOf(executor), balAfterPaying + 20 * 10**6, "claim did not pay");
        assertEq(ArbiterVaultFacet(address(diamond)).getRefundableBounty(executor), 0);
    }

    /// A reply of 1..31 bytes must stay soft. abi.decode panics on it by itself,
    /// which would make the branch written to be soft exactly as hard as before.
    function test_AShortTokenReplyKeepsTheAppealRefundSoft() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        _voteOverturn(agr, a2, a3, a4);

        // One byte back. Not `false`, not `true` — undecodable.
        vm.mockCall(
            address(usdc),
            abi.encodeWithSelector(bytes4(0xa9059cbb), executor, uint256(20 * 10**6)),
            hex"01"
        );
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);
        vm.clearMockedCalls();

        assertEq(
            ArbiterVaultFacet(address(diamond)).getRefundableBounty(executor),
            20 * 10**6,
            "a short reply was not treated as undelivered"
        );
    }

    /// The appeal is settled in storage BEFORE the deposit moves. Nothing in this
    /// facet is nonReentrant, so that order is the whole guard.
    function test_TheAppealIsSettledBeforeTheDepositMoves() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)
        uint256 balAfterPaying = usdc.balanceOf(executor);

        _voteOverturn(agr, a2, a3, a4);

        // A surplus in the diamond, deliberately. Without it the SECOND payment
        // runs the diamond out of USDC, the outer transfer reverts, and the whole
        // knock — including the flag recording it — rolls back with it: the
        // reorder would then be caught only by accident, and only while the
        // diamond happens to be exactly empty. In production it is not empty; it
        // holds the vault, the arbiters' rewards and the treasury slice, and a
        // double payment would come out of THAT. So the surplus is what makes
        // this lock test the real hazard rather than a bookkeeping coincidence.
        usdc.mint(address(diamond), 1_000 * 10**6);

        // Swap the token's code, keeping its balances: slots 0 and 1 match.
        vm.etch(address(usdc), address(new ReentrantUSDC()).code);
        ReentrantUSDC(address(usdc)).arm(address(diamond), agr);

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        // The knock must actually have happened, or this test locks nothing.
        assertTrue(ReentrantUSDC(address(usdc)).fired(), "the reentrant knock never fired");
        assertFalse(
            ReentrantUSDC(address(usdc)).reentryServed(),
            "a reentrant resolveAppeal was SERVED: state writes moved below the transfer"
        );
        // Paid once, not twice.
        assertEq(usdc.balanceOf(executor), balAfterPaying + 20 * 10**6, "deposit paid twice");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter),
            1,
            "the arbiter was punished twice for one verdict"
        );
    }

    /// The pot is per-ADDRESS, not per-cause. A second undelivered refund for the
    /// same man must ADD to what is already sitting there, never replace it.
    function test_AnUndeliveredDepositAddsToThePotItDoesNotReplaceIt() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        usdc.mint(executor, 200 * 10**6);

        uint256 firstPot;
        // ⚠️ THE WARP BELOW READS THE CLOCK THROUGH `vm.getBlockTimestamp()`
        // AND NOT THROUGH `block.timestamp`, and inside THIS loop that is the
        // difference between a green run and a red one (measured 24 September
        // 2026). `block.timestamp` compiles to TIMESTAMP, which via_ir is free
        // to treat as a loop invariant and hoist: both iterations then warped
        // to the same second, the second appeal's seats never opened, and the
        // scene failed with AppealSeatsNotOpenYet. The cheatcode is an external
        // call and cannot be hoisted.
        for (uint256 i = 0; i < 2; i++) {
            address agr = _disputeToVerdict(client, executor, true);
            vm.prank(executor);
            usdc.approve(address(diamond), 20 * 10**6);
            vm.prank(executor);
            ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
            vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

            _voteOverturn(agr, a2, a3, a4);

            vm.mockCall(
                address(usdc),
                abi.encodeWithSelector(bytes4(0xa9059cbb), executor, uint256(20 * 10**6)),
                abi.encode(false)
            );
            ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);
            vm.clearMockedCalls();

            // ⚠️ The won appeal was refunded out of the ruling arbiter's bond
            // (17 September 2026), so his seat now sags below the norm and
            // refuses the second verdict with BondNotPosted until topped up.
            // This scene is about the refund pot, not the seat: top it up.
            _bondSeat(arbiter);

            if (i == 0) {
                firstPot = ArbiterVaultFacet(address(diamond)).getRefundableBounty(executor);
                assertEq(firstPot, 20 * 10**6, "first deposit did not land in the pot");
            }
        }

        // Both are there. `+=`, not `=`.
        assertEq(
            ArbiterVaultFacet(address(diamond)).getRefundableBounty(executor),
            40 * 10**6,
            "the second undelivered deposit overwrote the first"
        );
    }

    /// Two overturn, one uphold — the standard winning shape.
    function _voteOverturn(address agr, address a2, address a3, address a4) internal {
        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
    }

    // ============================================================
    //  A CASE THAT HAS BEGUN LIVES BY THE RULES OF ITS BEGINNING — THE APPEAL
    //  DEPOSIT (26 August 2026)
    //
    //  The refund to a winning appellant used to be written as
    //  `transfer(v.appellant, APPEAL_DEPOSIT)` — what came back was the CONSTANT,
    //  not what had been paid in. Raise the deposit from $20 to $50 and whoever
    //  paid twenty received fifty; lower it to $10 and they received ten. Neither
    //  is their deposit; both are somebody else's money.
    //
    //  ⚠️ HOW THIS IS CHECKED. A compile-time constant cannot be changed at
    //  runtime — it is in the bytecode. The divergence "the rule of the record ≠
    //  today's rule" is introduced from the other end: an amount different from
    //  the current constant is put into the record, which is exactly the state a
    //  cut that changed the constant would have left behind. The expected numbers
    //  are literals chosen by a person.
    // ============================================================

    /// `pendingVerdicts` is field 6 in ArbiterRegistryStorage.Data (the
    /// neighbouring bond slot 12 was found by sweeping in the ArbiterSuspension
    /// suite and agrees), and `appealDeposit` is the seventh slot of the record,
    /// appended at the end of the struct.
    ///
    /// It is written AND READ BACK through the real getter: should the offset miss,
    /// the setup itself goes red rather than the scene, which would otherwise pass
    /// for somebody else's reason.
    function _setStoredAppealDeposit(address agr, uint256 amount) internal {
        bytes32 base = keccak256(
            abi.encode(
                agr,
                uint256(0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00) + 6
            )
        );
        vm.store(address(diamond), bytes32(uint256(base) + 6), bytes32(amount));
        assertEq(
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr).appealDeposit, amount,
            "the appealDeposit offset missed: the record did not change"
        );
    }

    /// ⚠️ THE APPEND IS MEASURED HERE, NOT CLAIMED IN A COMMENT. `frozenAt` was
    /// appended to `PendingVerdict` on 25 September 2026 (D6, the freeze gets a
    /// deadline), and "appended strictly at the end, nothing above it moved" is
    /// worth exactly as much as a check of where it landed.
    ///
    /// `appealDeposit` fills slot 6 of the record whole, so there were ZERO free
    /// bytes at the tail to pack into and the new field opens slot 7 — one cold
    /// SSTORE on a freeze, which only the owner or the DAO can press. The six free
    /// bytes that do exist inside slot 2 (six bools beside `appellant`) are
    /// unreachable to an append: solc packs in declaration order, and reaching
    /// them would mean moving a field, which is the one thing a live layout
    /// forbids.
    ///
    /// Both offsets are poked through the real getter in the same test, so a drift
    /// that moved one of them shows up as a disagreement rather than as a pass.
    function test_TheFreezeClockLandsOnTheSlotAfterTheAppealDeposit() public {
        address agr = address(0xA6E);
        bytes32 base = keccak256(
            abi.encode(
                agr,
                uint256(0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00) + 6
            )
        );

        vm.store(address(diamond), bytes32(uint256(base) + 6), bytes32(uint256(111)));
        vm.store(address(diamond), bytes32(uint256(base) + 7), bytes32(uint256(222)));

        ArbiterRegistryStorage.PendingVerdict memory v =
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr);
        assertEq(v.appealDeposit, 111, "appealDeposit moved off slot 6 - the layout drifted");
        assertEq(v.frozenAt, 222, "frozenAt is not on slot 7 - it was not appended at the end");
    }

    /// An appeal REMEMBERS what was paid in. Without that line in raiseAppeal all
    /// three scenes below would read a zero and take the fallback branch — that is,
    /// they would stay silent about precisely what they were written for.
    function test_RaiseAppealRecordsWhatWasActuallyPaid() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        assertEq(
            ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr).appealDeposit,
            20 * 10**6,
            "the record holds exactly what was taken from the person"
        );
    }

    /// THE REFUND FOLLOWS THE RECORD, NOT THE CONSTANT. A person paid twenty, the
    /// rule has changed since — SEVEN comes back, because that is what their own
    /// record says, and exactly the difference stays on the diamond.
    function test_TheRefundFollowsTheRecordAndNotTheConstant() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        uint256 balAfterPaying   = usdc.balanceOf(executor);
        uint256 diamondAfterPaying = usdc.balanceOf(address(diamond));
        _setStoredAppealDeposit(agr, 7 * 10**6);

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(
            usdc.balanceOf(executor), balAfterPaying + 7 * 10**6,
            "what came back is what the record says, not today's constant"
        );
        assertEq(
            usdc.balanceOf(address(diamond)), diamondAfterPaying - 7 * 10**6,
            "exactly as much left the diamond; it gave away nothing extra"
        );
    }

    /// AND THE FORFEIT TOO. A losing appellant loses exactly what is recorded.
    /// Half without the other half is worth nothing — should these two branches
    /// diverge, the diamond would start either overpaying or underpaying out of
    /// somebody else's money.
    ///
    /// ⚠️ Since 17 September 2026 a lost appeal's deposit pays the panel, so
    /// what follows the record is the panel's share: seven over three votes,
    /// 2.333333 each, and the one base unit left over into the vault. Twenty
    /// would have been 6.666666 and two units.
    function test_TheForfeitFollowsTheRecordAndNotTheConstant() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        _setStoredAppealDeposit(agr, 7 * 10**6);
        uint256 vaultBefore = ArbiterVaultFacet(address(diamond)).getVaultBalance();

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(
            ArbiterVaultFacet(address(diamond)).getVaultBalance(), vaultBefore + 1,
            "the vault took the remainder of what was recorded, not of today's price"
        );
        assertEq(
            ArbiterVaultFacet(address(diamond)).getAppealShareOwed(agr, a2), 2_333_333,
            "the panel is paid out of what was recorded, not out of today's price"
        );
    }

    /// An appeal filed BEFORE the field existed is judged by the constant then in
    /// force — and gets its twenty. The fallback branch deliberately does not
    /// revert: an appeal already paid for must not become unresolvable because of
    /// an upgrade.
    function test_AnAppealWithNoStoredDepositFallsBackToTheConstant() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        uint256 balAfterPaying = usdc.balanceOf(executor);
        _setStoredAppealDeposit(agr, 0);

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(
            usdc.balanceOf(executor), balAfterPaying + 20 * 10**6,
            "a pre-reform record is judged by the constant, and the person gets theirs in full"
        );
    }

    // ============================================================
    //  AN OVERTURN MUST OVERTURN (found reviewing the overturn counter, 21 August 2026)
    //
    //  overturnVerdict took ANY `newClientWins`, including the one the arbiter
    //  had already ruled. Such a press changed no outcome, and yet it slashed
    //  XP, booked a judicial mistake, and set `overturned`.
    //
    //  `overturned` is the flag resolveAppeal reads to tell a vindication from
    //  an overturn — it asks whether A HAND PRESSED, never whether the standing
    //  outcome differs from the arbiter's ruling. After an empty press the two
    //  became indistinguishable, and the wrong one was chosen: a panel voting
    //  for the OPPOSITE of the arbiter's ruling was read as acquitting him.
    //
    //  Which makes it a laundering route, not a curiosity: press into the same
    //  value, wait for a panel to disagree with the arbiter, and the record
    //  comes out clean — streak zero, overturns zero, and the chain's own
    //  accusation and suspension quashed if the empty press was the third
    //  mistake.
    //
    //  Inherited from an earlier change rather than introduced by this work, and fixed in
    //  the same cut because the line lives in the Replace group: after the cut
    //  it would cost a second irreversible transaction.
    // ============================================================

    // ⚠️ THIRTEEN LOCKS STOOD HERE AND ARE GONE (9 October 2026), together with
    // the three doors they were about: `overturnVerdict`, `freezeVerdict` and
    // `unfreezeVerdict`.
    //
    // Each one is named below with the reason THERE IS NO INPUT LEFT FOR IT, because
    // a deleted lock without that reason beside it is a hole hidden by tidying. Two
    // kinds of reason appear, and they are not the same strength:
    //
    //   * ABOUT THE DOOR ITSELF -- the scene's whole subject was a call to a function
    //     that no longer exists. Nothing can reach it, so nothing can regress.
    //   * STATE UNREACHABLE BY CONSTRUCTION -- the scene needed `v.overturned` to be
    //     TRUE BEFORE `resolveAppeal` ran. That flag now has exactly one writer and it
    //     is inside `resolveAppeal` itself, read before its own write, with one appeal
    //     per verdict. The state cannot be built any more. This reason is mechanical
    //     rather than remembered: test/ArbiterOverturnedHasOneWriter.t.sol counts the
    //     writers and goes red if a second one appears -- and if one ever does, these
    //     scenes have to come back, which is what that lock's failure message says.
    //
    // ⚠️ WHAT WAS **NOT** DELETED, so the distinction is on the record: one lock in
    // this file that looked like it was about the door is still here and was REWRITTEN
    // instead -- testRaiseAppeal_RevertsIfOwnerFrozeBeforeAnyAppeal. Its check
    // (`if (v.frozen) revert VerdictFrozenError()` in `raiseAppeal`) stays reachable
    // for verdicts a hand froze BEFORE this cut and that are still on chain, so the
    // scene builds that state with `vm.store` rather than through the gone door.
    //
    // ⚠️ `test_AnOverturnIntoTheSameOutcomeIsRefused` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF. The whole scene was `overturnVerdict(agr, <the
    //   outcome it already has>)` answering `VerdictUnchanged`. The error is kept
    //   (nothing in the facet raises it any more) but no caller can reach it.
    //
    // ⚠️ `test_ARealOverturnStillPassesAndVindicationStillWorks` IS GONE (9 October 2026).
    //   STATE UNREACHABLE BY CONSTRUCTION. It needed the hand to overturn first and
    //   the panel to restore the arbiter's ruling afterwards. The vindication
    //   branch of `resolveAppeal` that it exercised was deleted with the hand for
    //   this same reason, so the scene is now asserting the behaviour of code that
    //   is not there.
    //
    // ⚠️ `test_TheLaunderingRouteIsClosedAtItsFirstStep` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF, and its premise is now vacuous. It walked the
    //   laundering route -- an empty press to arm `overturned` without moving the
    //   outcome -- and stopped at step one. With no hand there is no step zero
    //   either: the property it protected ("after the hand pressed, a panel that
    //   flips the outcome is necessarily restoring the arbiter's ruling") is a
    //   statement about a hand that does not exist.
    //
    // ⚠️ `test_HandCannotDoubleCountAfterAppealOverturned` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF for the half it was named after -- the hand pressing
    //   ON TOP of a panel overturn and being refused.
    //   ⚠️ ITS SURVIVING HALF IS STILL COVERED, checked rather than assumed: the
    //   assertion that a panel-only overturn books exactly ONE mistake is made by
    //   testResolveAppeal_OverturnFlipsVerdictAndPenalizesArbiter, still in this
    //   file (`getArbiterMistakeStreak(arbiter) == 1` after resolveAppeal). The
    //   half that goes is only the hand's.
    //
    // ⚠️ `test_OverturnedWithAppealInFlightStillRefusesAsAppealInProgress` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF. It asserted which of two refusals `overturnVerdict`
    //   gives when an appeal is running (`AppealInProgress`, not
    //   `AlreadyOverturned`). Both errors are kept as declarations; nothing in the
    //   facet raises `AppealInProgress` any more, because the only function that
    //   did was this door.
    //
    // ⚠️ `test_PanelVindicatingTheArbiterClearsHisMistake` IS GONE (9 October 2026).
    //   STATE UNREACHABLE BY CONSTRUCTION -- hand overturns (mistake one), losing
    //   side appeals, panel flips back, the booking is taken off him. Step one is
    //   gone, so steps two to four cannot be entered.
    //
    // ⚠️ `test_VindicationAfterDemotionDoesNotUnderflowTheStreak` IS GONE (9 October 2026).
    //   STATE UNREACHABLE BY CONSTRUCTION. It drove the streak to the demotion
    //   threshold and then vindicated, to prove the subtraction could not wrap
    //   below zero. The subtraction itself is gone with the branch; there is no
    //   arithmetic left to underflow.
    //
    // ⚠️ `test_PanelVindicationTakesBackOneOverturn` IS GONE (9 October 2026).
    //   STATE UNREACHABLE BY CONSTRUCTION -- the same sequence, asserting that ONE
    //   overturn came back off `overturnedVerdicts` and not the whole count.
    //
    // ⚠️ `test_VindicationCannotUnderflowTheOverturnCount` IS GONE (9 October 2026).
    //   STATE UNREACHABLE BY CONSTRUCTION -- the `overturnedVerdicts` twin of the
    //   streak underflow scene above, and gone for the same reason.
    //
    // ⚠️ `testOverturnVerdictWorksWithNobodyToHearAnAppeal` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF. It pinned that the hand could still press when the
    //   corps was too small to hear an appeal. There is no hand to press.
    //
    // ⚠️ `testOverturnVerdict_RevertsDuringActiveAppeal` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF -- the same refusal as the scene above, reached by
    //   the older and plainer route.
    //
    // ⚠️ `testUnfreezeVerdict_RevertsDuringActiveAppeal` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF -- `unfreezeVerdict` refusing while an appeal runs.
    //
    // ⚠️ `testUnfreezeVerdict_WorksWithNoAppealInProgress` IS GONE (9 October 2026).
    //   ABOUT THE DOOR ITSELF -- the freeze/release pair pressed by hand.
    //   ⚠️ NOT the same thing as the freeze an APPEAL raises, which is alive and
    //   tested elsewhere: `raiseAppeal` still sets `v.frozen` and `resolveAppeal`
    //   still clears it, so the appeal's own hold has its own scenes.
    //
    // ============================================================
    //  ITEM 101 — THE OTHER HALF OF THE FRACTION (21 August 2026)
    //
    //  `arbiterMistakeStreak` is a streak IN A ROW, and finalizeVerdict clears
    //  it on every clean verdict. So "mistake, mistake, clean" round and round
    //  never reaches MAX_ARBITER_MISTAKES: the automatic path never fires, no
    //  matter how many overturns pile up. And the record showed the OPPOSITE of
    //  the truth — `cleanVerdicts` kept growing, so a man with six overturns
    //  read from outside as "three clean rulings, streak zero", better than an
    //  honest newcomer with nothing.
    //
    //  Nothing counted the overturns. Now something does, and it decides
    //  nothing: the rungs stop at "visible -> counted" by the owner's decision.
    // ============================================================

    /// One clean cycle: a fresh pair, a dispute, a verdict, and a finalization
    /// past FINALIZE_DELAY. Its own function rather than an inline block for
    /// the reason stated on _disputeAndOverturn — repeating this sequence
    /// inside one test body was observed to make later vm.warp/vm.roll calls
    /// silently no-op under this repo's via_ir build.
    function _disputeAndFinalizeClean(address cli, address exc) internal {
        address agr = _disputeToVerdict(cli, exc, true);
        vm.warp(vm.getBlockTimestamp() + 72 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
    }

    /// THE DESIGNATED SCENE for the overturn counter: alternation. Three rounds of "mistake,
    /// mistake, clean" — the exact order a patient bad arbiter would walk.
    ///
    /// What it pins, and every line of it was true BEFORE the fix except the
    /// last pair: the streak never passes two, the chain never accuses, the
    /// seat is never at risk, and judicial service keeps growing. That is the
    /// hole. What is new is that the overturns now leave a trace: six of them,
    /// standing beside three clean verdicts, for the reader to divide.
    ///
    /// What would disappear from behaviour if the increment were removed: this
    /// test, and the total it reads, and nothing else in the suite — which is
    /// the point. Every other counter in the file behaves identically with and
    /// without the fix, because the defect was an ABSENCE.
    function test_AlternatingMistakesLeaveTheStreakAtZeroAndTheTotalAtSix() public {
        // Round one.
        _disputeAndOverturn(address(0x7301), address(0x7302), arbiter);
        _disputeAndOverturn(address(0x7303), address(0x7304), arbiter);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 2,
            "two in a row, one short of the threshold, deliberately"
        );
        _disputeAndFinalizeClean(address(0x7305), address(0x7306));
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "and the clean verdict wipes the row"
        );

        // Round two.
        _disputeAndOverturn(address(0x7307), address(0x7308), arbiter);
        _disputeAndOverturn(address(0x7309), address(0x730A), arbiter);
        _disputeAndFinalizeClean(address(0x730B), address(0x730C));

        // Round three.
        _disputeAndOverturn(address(0x730D), address(0x730E), arbiter);
        _disputeAndOverturn(address(0x730F), address(0x7310), arbiter);
        _disputeAndFinalizeClean(address(0x7311), address(0x7312));

        // Everything the chain could see BEFORE this item, and all of it says
        // "nothing to see here".
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "six overturns later the streak still reads zero"
        );
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "and the chain never accused him once: the streak never reached three"
        );
        assertTrue(
            ArbiterVaultFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "and he keeps his seat, which is correct: no rung of this item unseats anyone"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getCleanVerdicts(arbiter), 3,
            "judicial service grew: this is the half that used to be the WHOLE record"
        );

        // And the half that was missing.
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter), 6,
            "six verdicts of his were overturned, and now the chain says so"
        );

        // The card hands the pair out together, because either number alone
        // misleads: three clean verdicts read as a good judge, six overturns
        // alone would punish a long-serving one.
        (, , , , , , , uint256 cleanVerdicts, uint256 overturned, , , , , )
            = ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(arbiter);
        assertEq(cleanVerdicts, 3, "the card's clean half");
        assertEq(overturned, 6, "the card's overturned half, standing right beside it");
    }

    /// THE COUNTER-SCENE: a timeout is a judicial mistake and NOT an overturn.
    ///
    /// notifyArbiterTimeout reaches _recordArbiterMistake like the other two
    /// paths, so an increment written without looking at `path` would count it
    /// — and would put a non-verdict in the numerator of a fraction whose
    /// denominator counts verdicts. The chain says as much itself two hundred
    /// lines up, where the timeout refuses to slash XP: there was no ruling to
    /// be wrong about.
    function test_AnArbiterTimeoutBooksAMistakeButNoOverturn() public {
        address flaky = address(uint160(51500));
        ArbiterRegistryFacet(address(diamond)).addArbiter(flaky);
        _bondSeat(flaky);

        _disputeAndArbiterTimeout(address(0x7401), address(0x7402), flaky, block.timestamp + 30 days);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(flaky), 1,
            "the silence is a judicial mistake and stays one"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(flaky), 0,
            "but nothing was overturned: there was no verdict at all"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getCleanVerdicts(flaky), 0,
            "and nothing was earned either: the pair stays honest about a non-verdict"
        );
    }

    /// ⚠️ REWRITTEN ON PURPOSE, 17 September 2026 (the owner's appeal
    /// economics). Until then this was `testResolveAppeal_UpholdForfeitsDepositNoPenalty`
    /// and asserted "the vault grows by the whole $20". Now the deposit pays the
    /// PANEL, equally, including the one arbiter who voted the other way — a
    /// vote is paid for being cast, not for which side it took — and only the
    /// remainder of the division goes to the vault. All three amounts literal.
    function testResolveAppeal_UpholdPaysThePanelNoPenalty() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        uint256 vaultBefore = ArbiterVaultFacet(address(diamond)).getVaultBalance();

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        // $20 over three votes: 6.666666 each, two base units left for the vault.
        assertEq(ArbiterVaultFacet(address(diamond)).getVaultBalance(), vaultBefore + 2, "only the remainder of the division");
        assertEq(ArbiterVaultFacet(address(diamond)).getAppealShareOwed(agr, a2), 6_666_666, "an upholding voter is paid");
        assertEq(ArbiterVaultFacet(address(diamond)).getAppealShareOwed(agr, a3), 6_666_666, "an upholding voter is paid");
        assertEq(ArbiterVaultFacet(address(diamond)).getAppealShareOwed(agr, a4), 6_666_666, "and so is the one who voted to overturn");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0);

        // Original verdict stands — client (winner) gets paid at finalization.
        vm.warp(block.timestamp + 72 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        assertEq(uint8(Agreement(agr).status()), uint8(Agreement.Status.RESOLVED));
    }

    // Tie vote (2 overturn vs. 2 uphold) at/above quorum must resolve to UPHOLD, not overturn,
    // since resolveAppeal() uses strict `>` (votesOverturn > votesUphold) to decide overturn.
    // Requires a 4th eligible voter beyond the 3 from _addAppealQuorumArbiters(), since the
    // ruling arbiter can't vote on its own verdict and 3 eligible voters can never tie.
    /// ⚠️ A TIE IS TWO VOTES NOW, NOT FOUR (23 September 2026). The panel has
    /// three seats and the fourth arbiter is refused, so 2-vs-2 is a tally that
    /// can no longer exist and three votes can never tie. The rule this scene
    /// holds is unchanged — a tie is not a majority, so the verdict stands —
    /// and it has moved to the only turnout that can still produce one.
    ///
    /// It also has to WAIT for the window: with a seat still open, a tie is not
    /// a reason to settle early, or the side the verdict favours could buy the
    /// outcome by pressing the door first.
    function testResolveAppeal_TiedVoteUpholdsNotOverturn() public {
        (address a2, address a3,) = _addAppealQuorumArbiters();

        address agr = _disputeToVerdict(client, executor, true); // client wins, executor loses

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        uint256 vaultBefore = ArbiterVaultFacet(address(diamond)).getVaultBalance();

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold

        // Confirm the tally really is a tie before resolving.
        (uint256 uphold, uint256 overturnVotes) = ArbiterVaultFacet(address(diamond)).getAppealVotes(agr);
        assertEq(uphold, 1);
        assertEq(overturnVotes, 1);

        vm.expectRevert(ArbiterRegistryFacet.AppealWindowNotClosed.selector);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);
        vm.warp(block.timestamp + 4 days + 1);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        // Tie with a panel seated -> uphold path taken: the ruling arbiter is
        // not penalized, and the two who did sit are paid $10 each out of the
        // $20, with nothing left over for the vault.
        assertEq(ArbiterVaultFacet(address(diamond)).getVaultBalance(), vaultBefore, "two votes divide $20 with no remainder");
        assertEq(ArbiterVaultFacet(address(diamond)).getAppealShareOwed(agr, a3), 10 * 10**6, "each of two voters is owed $10");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0);

        // Original verdict stands — client (winner) gets paid at finalization, not the executor.
        vm.warp(block.timestamp + 72 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        assertEq(uint8(Agreement(agr).status()), uint8(Agreement.Status.RESOLVED));
    }

    /// ⚠️ REWRITTEN ON PURPOSE, 17 September 2026 (the no-quorum refund).
    /// Until then this asserted "the vault grows by $20": a man paid for a
    /// review nobody gave, and the money went where it never comes back from.
    /// The verdict still stands by default — but the deposit goes home whole,
    /// and the lone voter is paid nothing, because no panel sat.
    function testResolveAppeal_NoQuorumUpholdsByDefaultAtWindowClose() public {
        (address a2,,) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        uint256 vaultBefore = ArbiterVaultFacet(address(diamond)).getVaultBalance();
        uint256 execBefore  = usdc.balanceOf(executor);

        // Only 1 of 3 needed votes cast — quorum never reached.
        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);

        vm.warp(block.timestamp + 4 days + 1); // APPEAL_REVIEW_WINDOW closes

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(ArbiterVaultFacet(address(diamond)).getVaultBalance(), vaultBefore, "the vault takes nothing from an unheard appeal");
        assertEq(usdc.balanceOf(executor) - execBefore, 20 * 10**6, "the whole deposit goes back to the appellant");
        assertEq(ArbiterVaultFacet(address(diamond)).getAppealShareOwed(agr, a2), 0, "a lone vote is not a panel and is not paid");
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0);
        assertTrue(ArbiterVaultFacet(address(diamond)).getPendingVerdict(agr).clientWins, "the verdict stands by default");
    }

    function testResolveAppeal_RevertsBeforeQuorumOrWindowClose() public {
        (address a2,,) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // only 1 of 3

        vm.expectRevert(ArbiterRegistryFacet.AppealWindowNotClosed.selector);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);
    }

    // Brief's Step 5 only exercises the AppealWindowNotClosed guard. resolveAppeal() has two
    // other guards (NoAppeal, AppealAlreadyResolved) that the task's own guard-trace
    // requirement calls for — neither was covered by the brief's own test list. Regression
    // test added during self-review, same pattern as Task 3/4's fix rounds.
    function testResolveAppeal_RevertsIfNoAppealOrAlreadyResolved() public {
        // NoAppeal: nobody ever called raiseAppeal on this verdict.
        address agrNoAppeal = _disputeToVerdict(client, executor, true);
        vm.expectRevert(ArbiterRegistryFacet.NoAppeal.selector);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agrNoAppeal);

        // AppealAlreadyResolved: resolve once successfully via quorum, then try again.
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1); // the seats open an hour after the appeal (24 September 2026)

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr); // resolves fine

        vm.expectRevert(ArbiterRegistryFacet.AppealAlreadyResolved.selector);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr); // second call must revert
    }

    /// The bond behind a hand-given seat (8 September 2026).
    ///
    /// `addArbiter` seats and takes no money, and since the bond gate landed a
    /// seated arbiter with a zero bond is refused by every arbiter door with
    /// `BondNotPosted`. The real door is `ArbiterApplicationsFacet.postArbiterBond`;
    /// this rig does not mount that facet, so the field is written directly —
    /// the same device this file already uses to seat.
    ///
    /// Slot 12 of the arbiter namespace is `arbiterBond`, pinned by
    /// test/StorageLayout.t.sol. The value is the real bond, 50 USDC at six
    /// decimals.
    ///
    /// ⚠️ NO USDC MOVES. That is deliberate and safe HERE only because nothing
    /// in this file refunds or forfeits a bond; a rig that does either must
    /// move real money instead, or the diamond pays out what it never took.
    /// ⚠️ THERE IS NO SEAT BOND ANY MORE (22 September 2026), so this no
    /// longer writes `arbiterBond` slot 12 by hand. What a seated arbiter now
    /// needs is money and an allowance for the bond he posts PER CASE, inside
    /// `claimDispute`. The name is kept because every rig in this file calls it.
    function _bondSeat(address who) internal {
        usdc.mint(who, CASE_BOND_PURSE);
        vm.prank(who);
        usdc.approve(address(diamond), type(uint256).max);
    }

    /// Generous on purpose: a case bond is a percentage of the pot with a $20
    /// floor, and a rig that ran out would fail with `CaseBondTransferFailed`
    /// in the middle of a scene about something else.
    uint256 constant CASE_BOND_PURSE = 1_000_000_000;

}