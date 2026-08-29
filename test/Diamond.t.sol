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

contract DiamondTest is Test {
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
        ReputationFacet reputationFacet = new ReputationFacet();
        
        // RegistryFacet selectors
        bytes4[] memory registrySelectors = new bytes4[](12);
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
        bytes4[] memory arbiterSelectors = new bytes4[](40);
        arbiterSelectors[0] = ArbiterRegistryFacet.setChiefArbiter.selector;
        arbiterSelectors[1] = ArbiterRegistryFacet.addArbiter.selector;
        arbiterSelectors[2] = ArbiterRegistryFacet.commitDisputeClaim.selector;
        arbiterSelectors[3] = ArbiterRegistryFacet.claimDispute.selector;
        arbiterSelectors[4] = ArbiterRegistryFacet.releaseDisputeClaim.selector;
        arbiterSelectors[5] = ArbiterRegistryFacet.clearDisputeClaim.selector;
        arbiterSelectors[6] = ArbiterRegistryFacet.getChiefArbiter.selector;
        arbiterSelectors[7] = ArbiterRegistryFacet.isRegisteredArbiter.selector;
        arbiterSelectors[8] = ArbiterRegistryFacet.getArbiters.selector;
        arbiterSelectors[9] = ArbiterRegistryFacet.getDisputeClaimer.selector;
        arbiterSelectors[10] = ArbiterRegistryFacet.getClaimCommitment.selector;
        arbiterSelectors[11] = ArbiterRegistryFacet.activateDAO.selector;
        arbiterSelectors[12] = ArbiterRegistryFacet.applyAsArbiter.selector;
        arbiterSelectors[13] = ArbiterRegistryFacet.isDaoActive.selector;
        arbiterSelectors[14] = ArbiterRegistryFacet.getMinXPToRegister.selector;
        arbiterSelectors[15] = ArbiterRegistryFacet.getDaoThreshold.selector;
        arbiterSelectors[16] = ArbiterRegistryFacet.submitVerdict.selector;
        arbiterSelectors[17] = ArbiterRegistryFacet.finalizeVerdict.selector;
        arbiterSelectors[18] = ArbiterRegistryFacet.overturnVerdict.selector;
        arbiterSelectors[19] = ArbiterRegistryFacet.freezeVerdict.selector;
        arbiterSelectors[20] = ArbiterRegistryFacet.unfreezeVerdict.selector;
        arbiterSelectors[21] = ArbiterRegistryFacet.withdrawArbiterReward.selector;
        arbiterSelectors[22] = ArbiterRegistryFacet.fundVault.selector;
        arbiterSelectors[23] = ArbiterRegistryFacet.setRewardPerDispute.selector;
        arbiterSelectors[24] = ArbiterRegistryFacet.setDAOAddress.selector;
        arbiterSelectors[25] = ArbiterRegistryFacet.getPendingVerdict.selector;
        arbiterSelectors[26] = ArbiterRegistryFacet.getVaultBalance.selector;
        arbiterSelectors[27] = ArbiterRegistryFacet.getRewardPerDispute.selector;
        arbiterSelectors[28] = ArbiterRegistryFacet.getDAOAddress.selector;
        arbiterSelectors[29] = ArbiterRegistryFacet.clearStuckVerdict.selector;
        arbiterSelectors[30] = ArbiterRegistryFacet.notifyArbiterTimeout.selector;
        arbiterSelectors[31] = ArbiterRegistryFacet.resignAsArbiter.selector;
        arbiterSelectors[32] = ArbiterRegistryFacet.hasSubmittedVerdict.selector;
        arbiterSelectors[33] = ArbiterRegistryFacet.raiseAppeal.selector;
        arbiterSelectors[34] = ArbiterRegistryFacet.voteOnAppeal.selector;
        arbiterSelectors[35] = ArbiterRegistryFacet.resolveAppeal.selector;
        arbiterSelectors[36] = ArbiterRegistryFacet.getAppealVotes.selector;
        arbiterSelectors[37] = ArbiterRegistryFacet.hasVotedOnAppeal.selector;
        // The second step of handing over the DAO address (26 August 2026).
        arbiterSelectors[38] = ArbiterRegistryFacet.acceptDAOAddress.selector;
        arbiterSelectors[39] = ArbiterRegistryFacet.getPendingDAOAddress.selector;

        // These readers live in ArbiterAccountabilityFacet, so that is the
        // facet they have to be mounted on. Leaving them in the list above
        // would route them to a facet that does not implement them — the
        // call arrives and reverts.
        bytes4[] memory accSels = new bytes4[](12);
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

        // ReputationFacet selectors
        bytes4[] memory reputationSelectors = new bytes4[](8);
        reputationSelectors[0] = ReputationFacet.claimXP.selector;
        reputationSelectors[1] = ReputationFacet.getXP.selector;
        reputationSelectors[2] = ReputationFacet.getUniqueActiveUsers.selector;
        reputationSelectors[3] = ReputationFacet.hasClaimed.selector;
        reputationSelectors[4] = ReputationFacet.isDealWin.selector;
        reputationSelectors[5] = ReputationFacet.autoAwardXP.selector;
        reputationSelectors[6] = ReputationFacet.notifyExecutorFault.selector;
        reputationSelectors[7] = ReputationFacet.getCleanStreak.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](8);
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

        diamond = new DiamondProxy(owner, cut, address(0), "");
        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));

        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        FactoryFacet(address(diamond)).initFactory(address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer));
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
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

    // Full deploy -> fund -> activate -> dispute -> claim -> submit -> overturn cycle against a
    // single fresh counterparty pair, for arbiter-mistake-streak tests. Kept as its own
    // function (called explicitly per-mistake rather than from a `for` loop) — looping this
    // sequence directly inside one test function was observed to make later vm.roll calls not
    // take effect under this repo's via_ir compilation; calling a helper repeatedly does not
    // have that problem.
    function _disputeAndOverturn(address cli, address exec, address arbiterAddr) internal returns (address agreementAddr) {
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

        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agreementAddr, false);
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
        ArbiterRegistryFacet(address(diamond)).addArbiter(a3);
        ArbiterRegistryFacet(address(diamond)).addArbiter(a4);
    }

    // The new flow: the arbiter through the Diamond (submitVerdict → finalizeVerdict)
    function _resolveDispute(address agreementAddr, bool clientWins) internal {
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreementAddr, clientWins);
        vm.warp(block.timestamp + 24 hours + 1);
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

    function testClientXPFrozenAbove1000() public {
        address bigClient = address(uint160(31000));
        _growXP(bigClient, false, 1000, 31500);
        uint256 xpAtThreshold = ReputationFacet(address(diamond)).getXP(bigClient);
        assertGe(xpAtThreshold, 1000);

        address freshExecutor = address(uint160(31999));
        _completeDeal(bigClient, freshExecutor);

        assertEq(ReputationFacet(address(diamond)).getXP(bigClient), xpAtThreshold);
    }

    function testExecutorXPGatedByStreakAbove1000() public {
        address bigExecutor = address(uint160(32000));
        _growXP(bigExecutor, true, 1000, 32500);
        uint256 xpAtThreshold = ReputationFacet(address(diamond)).getXP(bigExecutor);
        assertGe(xpAtThreshold, 1000);
        // _growXP only ever uses fresh counterparties with clean releases, so by construction
        // the streak that carried this address past 1000 XP is already >= CLEAN_STREAK_REQUIRED (10).
        assertGe(ReputationFacet(address(diamond)).getCleanStreak(bigExecutor), 10);

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
        _resolveDispute(disputedAgreement, true); // client wins — executor loses, streak resets to 0

        assertEq(ReputationFacet(address(diamond)).getCleanStreak(bigExecutor), 0);

        // One clean deal right after the reset: streak stays below 10 either way (this
        // counterparty is also fresh, so it doesn't even count toward the streak under
        // Mechanism 1) — no XP granted regardless.
        uint256 xpAfterLoss = ReputationFacet(address(diamond)).getXP(bigExecutor);
        address freshClient1 = address(uint160(32901));
        usdc.mint(freshClient1, 1_000_000 * 10**6);
        _completeDeal(freshClient1, bigExecutor);
        assertEq(ReputationFacet(address(diamond)).getXP(bigExecutor), xpAfterLoss);

        // Rebuild the streak to 10. Mechanism 1 requires each deal's client to already
        // have >= MIN_COUNTERPARTY_XP (50) — a single warmed-up counterparty, reused
        // across all 11 deals (warmup + 10 counted), satisfies this without hitting MAX_WINS_PAIR
        // (that cap only gates the win/volume XP bonus, not cleanStreak accounting). The warmup
        // deal gives the counterparty initial XP; the next 10 deals all count toward the streak.
        address streakClient = address(uint160(33000));
        usdc.mint(streakClient, 1_000_000 * 10**6);
        _warmUpClientXP(streakClient);
        for (uint256 i = 0; i < 10; i++) {
            _completeDeal(streakClient, bigExecutor);
        }
        assertEq(ReputationFacet(address(diamond)).getCleanStreak(bigExecutor), 10);

        // The deal that brought the streak to exactly 10 already counts under the new rule.
        uint256 xpAtStreak10 = ReputationFacet(address(diamond)).getXP(bigExecutor);
        assertGt(xpAtStreak10, xpAfterLoss);
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

    function testPhase2XPBlockedWhenDealCounterpartyBelowMinXP() public {
        address bigExecutor = address(uint160(35100));
        _growXP(bigExecutor, true, 1000, 35500);
        assertGe(ReputationFacet(address(diamond)).getXP(bigExecutor), 1000);
        assertGe(ReputationFacet(address(diamond)).getCleanStreak(bigExecutor), 10);

        uint256 xpBefore = ReputationFacet(address(diamond)).getXP(bigExecutor);
        address freshClient = address(uint160(35999));
        usdc.mint(freshClient, 1_000_000 * 10**6);
        _completeDeal(freshClient, bigExecutor);

        assertEq(ReputationFacet(address(diamond)).getXP(bigExecutor), xpBefore);
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
        vm.expectRevert(abi.encodeWithSelector(ArbiterRegistryFacet.InsufficientCleanStreak.selector, 0, 10));
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();
    }

    function testApplyAsArbiterSucceedsWithBothConditions() public {
        _handGovernanceToDao(address(0xDA0));

        address candidate = address(uint160(41000));
        _growXP(candidate, true, 3000, 41500);
        assertGe(ReputationFacet(address(diamond)).getXP(candidate), 3000);
        assertGe(ReputationFacet(address(diamond)).getCleanStreak(candidate), 10);

        vm.prank(candidate);
        usdc.approve(address(diamond), ARBITER_BOND);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(candidate));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), ARBITER_BOND);
    }

    /// ⚠️ A PREMISE OF THE PUBLIC DOCUMENT.
    ///
    /// docs/DECENTRALIZATION.md states that today the arbiter corps cannot be
    /// entered by any road but the owner's hand: self-enrolment is locked until
    /// the DAO is switched on. The whole paragraph stands on ONE line of code —
    /// `if (!isDaoActive()) revert DAONotActive();`, the first line of
    /// applyAsArbiter.
    ///
    /// Until this test NOTHING guarded that line: removing it gave 0 red out of
    /// 852, and the word `DAONotActive` appeared in the whole of test/ exactly
    /// once, and that inside a docstring as text. The document's claim could have
    /// become false in silence — and today's unreachability of the arbiter open
    /// items rests on it too ("there is one arbiter, and it is the owner").
    ///
    /// The candidate here is eligible ON EVERY OTHER COUNT — XP, clean streak,
    /// an approved bond — that is, without the DAO gate the call WOULD HAVE gone
    /// through. That is what makes the measurement honest: removing the line does
    /// not shift the failure onto a neighbouring cause, it removes the failure
    /// altogether, and expectRevert goes red by itself.
    ///
    /// The mirror of the scene is testApplyAsArbiterSucceedsWithBothConditions
    /// above: the same candidate, the same preparation, the DAO switched on, and
    /// self-enrolment goes through. The pair clamps the gate from both sides.
    function testApplyAsArbiterRevertsWhileTheDaoSleeps() public {
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
        usdc.approve(address(diamond), ARBITER_BOND);

        vm.prank(candidate);
        vm.expectRevert(ArbiterRegistryFacet.DAONotActive.selector);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(candidate),
            "he did not get into the corps"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), 0,
            "and no bond was taken from him"
        );
    }

    function testArbiterDemotedAfterThreeOverturns() public {
        address flakyArbiter = address(uint160(42000));
        ArbiterRegistryFacet(address(diamond)).addArbiter(flakyArbiter);

        _disputeAndOverturn(address(uint160(42100)), address(uint160(42200)), flakyArbiter);
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));

        _disputeAndOverturn(address(uint160(42101)), address(uint160(42201)), flakyArbiter);
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));

        _disputeAndOverturn(address(uint160(42102)), address(uint160(42202)), flakyArbiter);

        // ⚠️ THE SCENE WAS REBUILT WHEN THE THIRD MISTAKE STOPPED REMOVING.
        // It now SUSPENDS AND ACCUSES in the chain's name, and the takedown goes
        // through the common door after 48 hours. XP is cut as before (the seat is
        // touched, not the points), and the counter is DELIBERATELY not reset: a
        // streak of judging mistakes has not ended just because the chain noticed
        // it. The button does not need the counter anyway — it reads the RECORD and
        // fires at zero, and ten lines below it is pressed in this very scene.
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));
        assertEq(ReputationFacet(address(diamond)).getXP(flakyArbiter), 2500);
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(flakyArbiter), 3);
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(flakyArbiter));
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).isSuspended(flakyArbiter));

        // And the second half of the same scene: after the pause anybody may press.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(address(uint160(42999)));
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(flakyArbiter);

        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(flakyArbiter), 0);
    }

    function testArbiterDemotionResetIsFlatNotSubtractive() public {
        // An arbiter with a large pre-existing XP balance must still land at exactly 2500,
        // not 2500-minus-something or their-balance-minus-a-fixed-amount.
        address veteranArbiter = address(uint160(43000));
        _growXP(veteranArbiter, true, 10_000, 43500);
        uint256 xpBeforeDemotion = ReputationFacet(address(diamond)).getXP(veteranArbiter);
        assertGe(xpBeforeDemotion, 10_000);
        ArbiterRegistryFacet(address(diamond)).addArbiter(veteranArbiter);

        _disputeAndOverturn(address(uint160(43100)), address(uint160(43200)), veteranArbiter);
        _disputeAndOverturn(address(uint160(43101)), address(uint160(43201)), veteranArbiter);
        _disputeAndOverturn(address(uint160(43102)), address(uint160(43202)), veteranArbiter);

        assertEq(ReputationFacet(address(diamond)).getXP(veteranArbiter), 2500);
    }

    function testApplyAsArbiterPullsBond() public {
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(45000));
        _growXP(candidate, true, 3000, 45500);

        uint256 balanceBefore = usdc.balanceOf(candidate);
        vm.prank(candidate);
        usdc.approve(address(diamond), ARBITER_BOND);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), ARBITER_BOND);
        assertEq(usdc.balanceOf(candidate), balanceBefore - ARBITER_BOND);
    }

    function testApplyAsArbiterRevertsWithoutBondApproval() public {
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(45100));
        _growXP(candidate, true, 3000, 45600);

        vm.prank(candidate);
        vm.expectRevert("Allowance exceeded");
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();
    }

    function testArbiterBondForfeitedOnDemotion() public {
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(45200));
        _growXP(candidate, true, 3000, 45700);
        vm.prank(candidate);
        usdc.approve(address(diamond), ARBITER_BOND);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        uint256 vaultBefore = ArbiterRegistryFacet(address(diamond)).getVaultBalance();

        _disputeAndOverturn(address(uint160(45800)), address(uint160(45900)), candidate);
        _disputeAndOverturn(address(uint160(45801)), address(uint160(45901)), candidate);
        _disputeAndOverturn(address(uint160(45802)), address(uint160(45902)), candidate);

        // ⚠️ THE BOND BURNS ON REMOVAL, NOT ON ACCUSATION. Until the pause is over
        // the person is still an arbiter and the money is still theirs — an
        // accusation is not a punishment.
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), ARBITER_BOND,
            "the chain's accusation does not touch the money"
        );

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(address(uint160(45999)));
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(candidate);

        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(candidate));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), 0);
        assertEq(ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore + ARBITER_BOND);
    }

    function testResignAsArbiterRefundsBondAndClearsStatus() public {
        _handGovernanceToDao(address(0xDA0));
        address candidate = address(uint160(45300));
        _growXP(candidate, true, 3000, 45400);
        vm.prank(candidate);
        usdc.approve(address(diamond), ARBITER_BOND);
        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();

        uint256 balanceAfterApply = usdc.balanceOf(candidate);

        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();

        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(candidate));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(candidate), 0);
        assertEq(usdc.balanceOf(candidate), balanceAfterApply + ARBITER_BOND);
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
        vm.warp(block.timestamp + 24 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getOpenClaimCount(candidate), 0);

        vm.prank(candidate);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();

        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(candidate));
    }

    function testFinalizedVerdictResetsMistakeStreak() public {
        address recoveringArbiter = address(uint160(44000));
        ArbiterRegistryFacet(address(diamond)).addArbiter(recoveringArbiter);

        // One overturn — mistake streak becomes 1.
        address cli1 = address(uint160(44100));
        usdc.mint(cli1, 1_000_000 * 10**6);
        vm.prank(cli1);
        usdc.approve(address(diamond), 10 * 10**6);
        address exec1 = address(uint160(44200));
        vm.prank(address(diamond));
        address agreement1 = FactoryFacet(address(diamond)).deployAgreement(
            cli1, exec1, recoveringArbiter, AMOUNT, DEADLINE, TERMS_HASH, 0
        );
        vm.prank(cli1);
        usdc.approve(agreement1, AMOUNT);
        vm.prank(cli1);
        Agreement(agreement1).fund();
        vm.prank(exec1);
        Agreement(agreement1).activate();
        vm.prank(cli1);
        Agreement(agreement1).raiseDispute();
        _claimDisputeAs(agreement1, recoveringArbiter);
        vm.prank(recoveringArbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreement1, true);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agreement1, false);
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
        vm.warp(block.timestamp + 24 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreement2);

        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(recoveringArbiter), 0);
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(recoveringArbiter));
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

        _disputeAndArbiterTimeout(address(uint160(51100)), address(uint160(51200)), flakyArbiter, 10_000_000);
        _disputeAndArbiterTimeout(address(uint160(51101)), address(uint160(51201)), flakyArbiter, 20_000_000);
        _disputeAndArbiterTimeout(address(uint160(51102)), address(uint160(51202)), flakyArbiter, 30_000_000);

        // ⚠️ The third timeout accuses; removal goes through the common door.
        // It is separately valuable that the timeout path GOT THERE at all:
        // Agreement calls notifyArbiterTimeout inside an EMPTY try/catch, and a
        // revert in the new branch would have been swallowed in silence — "not
        // punished" would have looked exactly like "punished".
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(flakyArbiter));
        assertEq(ReputationFacet(address(diamond)).getXP(flakyArbiter), 2500);

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(address(uint160(51999)));
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(flakyArbiter);

        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(flakyArbiter));
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
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(newArbiter));
        address[] memory list = ArbiterRegistryFacet(address(diamond)).getArbiters();
        assertEq(list.length, 2); // arbiter from setUp + new
    }

    function testArbiterRegistryAddRevertIfAlreadyArbiter() public {
        vm.expectRevert(ArbiterRegistryFacet.AlreadyArbiter.selector);
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
    }

    function testArbiterRegistryAddRevertIfNotOwner() public {
        vm.prank(client);
        vm.expectRevert(ArbiterRegistryFacet.NotOwnerOrChief.selector);
        ArbiterRegistryFacet(address(diamond)).addArbiter(address(0x10));
    }

    // testArbiterRegistryRemoveArbiter / testArbiterRegistryRemoveRevertIfNotArbiter
    // were deleted on 15 August 2026: removeArbiter was taken off the facet
    // entirely, and its replacement is
    // ArbiterAccountabilityFacet.removeArbiterForCause (the ArbiterRemovalForCause
    // suite).

    function testArbiterRegistryChiefCanAdd() public {
        address chief = address(0x20);
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(chief);
        assertEq(ArbiterRegistryFacet(address(diamond)).getChiefArbiter(), chief);

        vm.prank(chief);
        ArbiterRegistryFacet(address(diamond)).addArbiter(address(0x21));
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(address(0x21)));
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

        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeClaimer(agreementAddr), arbiter);
        // After claimDispute the Diamond (not the individual arbiter) becomes the Agreement's arbiter
        assertEq(Agreement(agreementAddr).arbiter(), address(diamond));

        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).releaseDisputeClaim(agreementAddr);

        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeClaimer(agreementAddr), address(0));
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
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeClaimer(agreementAddr), address(0));
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
        vm.warp(block.timestamp + 24 hours + 1);
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
        assertEq(ArbiterRegistryFacet(address(diamond)).getDisputeClaimer(agreementAddr), address(0));
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
        assertEq(usdc.balanceOf(address(diamond)), diamondBalBefore + 20 * 10**6);

        // Frozen — finalizeVerdict can't proceed until the appeal resolves.
        vm.warp(block.timestamp + 24 hours + 1);
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

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(executor);
        vm.expectRevert(ArbiterRegistryFacet.AppealWindowClosed.selector);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
    }

    function testRaiseAppeal_RevertsWithTooFewArbiters() public {
        // No extra arbiters registered — only the default `arbiter` exists.
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);

        vm.prank(executor);
        vm.expectRevert(ArbiterRegistryFacet.InsufficientArbitersForAppeal.selector);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
    }

    function testRaiseAppeal_RevertsIfOwnerFrozeBeforeAnyAppeal() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // client wins, executor loses

        // Owner/DAO freezes the verdict (e.g. pending investigation) before anyone appeals.
        ArbiterRegistryFacet(address(diamond)).freezeVerdict(agr);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);

        vm.prank(executor);
        vm.expectRevert(ArbiterRegistryFacet.VerdictFrozenError.selector);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        ArbiterRegistryStorage.PendingVerdict memory v = ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr);
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

        ArbiterRegistryStorage.PendingVerdict memory before = ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr);
        assertEq(before.votesOverturn, 0);
        assertEq(before.votesUphold, 0);

        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterRegistryFacet.AppealVoteCast(agr, a2, true);
        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);

        // Successful vote incremented the right tally (overturn) and left the other untouched.
        ArbiterRegistryStorage.PendingVerdict memory afterVote = ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr);
        assertEq(afterVote.votesOverturn, 1);
        assertEq(afterVote.votesUphold, 0);

        vm.prank(a2);
        vm.expectRevert(ArbiterRegistryFacet.AlreadyVoted.selector);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);

        // Repeat-vote revert must not have double-counted.
        ArbiterRegistryStorage.PendingVerdict memory afterRevert = ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr);
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

        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterRegistryFacet.AppealVoteCast(agr, a2, true);
        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // a2 votes to overturn

        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterRegistryFacet.AppealVoteCast(agr, a3, false);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // a3 votes to uphold — different arbiter, no revert

        // Both votes recorded distinctly in the tally.
        ArbiterRegistryStorage.PendingVerdict memory v = ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr);
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
        vm.warp(block.timestamp + 24 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        assertEq(usdc.balanceOf(executor), executorBalBefore - 20 * 10**6 + 20 * 10**6 + AMOUNT);
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
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr).appealDeposit, amount,
            "the appealDeposit offset missed: the record did not change"
        );
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

        assertEq(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr).appealDeposit,
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

    /// AND THE FORFEIT TOO. A losing appellant loses exactly what is recorded: the
    /// arbiter vault grows by seven, not by twenty. Half without the other half is
    /// worth nothing — should these two branches diverge, the diamond would start
    /// either overpaying or underpaying out of somebody else's money.
    function test_TheForfeitFollowsTheRecordAndNotTheConstant() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        _setStoredAppealDeposit(agr, 7 * 10**6);
        uint256 vaultBefore = ArbiterRegistryFacet(address(diamond)).getVaultBalance();

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore + 7 * 10**6,
            "the vault took what was recorded, not today's constant"
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

    /// THE DESIGNATED SCENE: the hand presses the value the arbiter already
    /// ruled, and the chain refuses.
    function test_AnOverturnIntoTheSameOutcomeIsRefused() public {
        address agr = _disputeToVerdict(client, executor, true); // arbiter: client wins

        vm.expectRevert(ArbiterRegistryFacet.VerdictUnchanged.selector);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, true);

        // Nothing was paid for the refused press: no mistake, no flag, no
        // slash. Asserted rather than assumed — a revert that had already
        // written state would be the same defect one layer down.
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "a press that changed nothing must cost nothing"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter), 0,
            "and it must not count as an overturned verdict either"
        );
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr).overturned,
            "and the flag every reader trusts must stay false"
        );
    }

    /// THE COUNTER-SCENE, and it matters more than the first: a REAL overturn
    /// still goes through, and a panel vindicating the arbiter after it still
    /// works. A guard written as "refuse the hand" rather than "refuse an empty
    /// press" would pass the scene above and quietly kill the owner's door and
    /// the only check on it.
    function test_ARealOverturnStillPassesAndVindicationStillWorks() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // arbiter: client wins

        // The real press: the OTHER value. Books the one mistake and the one
        // overturn, exactly as before the guard.
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1,
            "a real overturn still books its mistake"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter), 1,
            "and still counts as an overturned verdict"
        );

        // And the panel can still take it back. The hand flipped clientWins to
        // false, so the client is the loser and the one who may appeal.
        usdc.mint(client, 100 * 10**6);
        vm.prank(client);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr).clientWins,
            "the panel restored the arbiter's own ruling, as it could before"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "and the vindication still reaches the streak"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter), 0,
            "and the overturn count"
        );
    }

    /// The premise the guard exists to make true, stated as a scene rather than
    /// as a comment: after the hand has pressed, a panel that flips the outcome
    /// is necessarily restoring the ARBITER'S ruling. Before the guard this was
    /// merely usually so, and the exception was the laundering route.
    ///
    /// What this pins that the two above do not: it walks the laundering path
    /// itself as far as the chain now allows, and stops at the first step.
    function test_TheLaunderingRouteIsClosedAtItsFirstStep() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, false); // arbiter: executor wins

        // Step one of the route: an empty press, to arm `overturned` without
        // moving the outcome. There is no step two.
        vm.expectRevert(ArbiterRegistryFacet.VerdictUnchanged.selector);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr).overturned,
            "the flag stays false, so a later panel vote cannot be read as an acquittal"
        );
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr).clientWins,
            "and the arbiter's ruling stands untouched"
        );
    }

    // Task 11, 18 August 2026: the vote may still overturn a verdict, but a hand
    // on top of it may not. resolveAppeal sets `overturned` too, so the hand is
    // refused — it would otherwise have booked a SECOND mistake against the
    // same verdict, which is what it used to do. One verdict earns AT MOST one
    // judicial mistake, whoever books it.
    //
    // ⚠️ "At most", not "one", and resolveAppeal's own booking is not a fixed
    // property of the function — both depend on the ORDER:
    //
    //   panel only (this scene)  — resolveAppeal books the one mistake;
    //   hand, then panel         — resolveAppeal books NOTHING and takes the
    //                              hand's booking back, so the verdict ends up
    //                              having earned zero. That scene is
    //                              test_PanelVindicatingTheArbiterClearsHisMistake.
    function test_HandCannotDoubleCountAfterAppealOverturned() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // client wins, executor loses

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1,
            "the vote booked the one mistake this verdict earns"
        );

        vm.expectRevert(ArbiterRegistryFacet.AlreadyOverturned.selector);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, true);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1,
            "the hand added nothing on top"
        );
    }

    // Placement, half two: an appeal raised ON TOP of a hand overturn is
    // reachable — overturnVerdict clears `frozen`, so raiseAppeal passes and
    // leaves appealed=true, appealResolved=false with overturned already true.
    // The refusal there must stay AppealInProgress: a vote is running and that
    // is the larger fact. Lifting the new gate above the appeal check swaps the
    // reason a person reads.
    function test_OverturnedWithAppealInFlightStillRefusesAsAppealInProgress() public {
        _addAppealQuorumArbiters(); // quorum only — no vote is cast here
        address agr = _disputeToVerdict(client, executor, true); // client wins

        // Hand overturn flips clientWins to false: the CLIENT is now the loser
        // and the one who may appeal.
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);

        usdc.mint(client, 100 * 10**6);
        vm.prank(client);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.expectRevert(ArbiterRegistryFacet.AppealInProgress.selector);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, true);
    }

    // Found on review of the one-mistake-per-verdict gate, 18 August 2026. It
    // closed the hand
    // pressing twice; it did not close the OTHER way to book two mistakes
    // against one verdict, and that way runs through an honest panel.
    //
    //   arbiter rules clientWins=true
    //   → owner's hand overturns to false            (mistake 1, XP slashed)
    //   → raiseAppeal still passes: the hand cleared `frozen`, and the appeal
    //     window runs from the VERDICT, not from the overturn
    //   → the panel votes to overturn, flipping back to true
    //
    // The panel has just said the ARBITER was right and the owner was wrong —
    // and the old code thanked him with a second mistake, a second XP slash,
    // and a permanent record reading DemotionPath.AppealVote: the chain
    // asserting "the panel found him wrong" exactly where it found the
    // opposite. Measured consequence: two disputes unseated an arbiter instead
    // of three, and no collusion was needed — a correct panel decision handed
    // the owner the second mistake for free.
    //
    // Raising an appeal after a hand overturn must stay open: it is the only
    // check on the owner there is. So the second booking is what goes.
    function test_PanelVindicatingTheArbiterClearsHisMistake() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // arbiter: client wins

        // ⚠️ SEED XP FIRST, and this line is not decoration. _slashArbiterXP
        // floors at zero and this arbiter starts at zero, so without a balance
        // the "no second slash" assertion at the end compares 0 to 0 and guards
        // nothing at all. Measured: with the slash hoisted out of the guard but
        // the mistake booking left inside it, the whole suite gave ZERO red
        // until this line existed — a dead assertion that looked alive.
        vm.store(address(diamond), keccak256(abi.encode(arbiter, uint256(REP_BASE))), bytes32(uint256(1000)));
        assertEq(ReputationFacet(address(diamond)).getXP(arbiter), 1000, "setup: XP seeded");

        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1,
            "the hand booked the one mistake this verdict earns"
        );
        uint256 xpAfterHand = ReputationFacet(address(diamond)).getXP(arbiter);
        assertEq(xpAfterHand, 800, "setup: the hand's slash must be visible, 1000 - OVERTURN_XP_SLASH");

        // The hand flipped clientWins to false, so the CLIENT is the loser now
        // and the one who may appeal.
        usdc.mint(client, 100 * 10**6);
        vm.prank(client);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(client);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        // The panel restored the arbiter's own ruling — proof the vote went
        // AGAINST the owner, not against the arbiter.
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr).clientWins,
            "scene is not the one: the panel must have restored the arbiter's ruling"
        );

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "the panel said there was no judicial mistake, so no mark may stand"
        );
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "and he keeps his seat"
        );

        // The counter comes back; the points do not. _slashArbiterXP floors at
        // zero and never records how much it took, so adding the constant back
        // would invent points for an arbiter slashed into the floor. What did
        // change: the slash is ONE instead of two — the second left together
        // with the booking.
        //
        // ⚠️ He keeps his seat HERE because he never lost it — this is his
        // first mistake. Vindication does not GIVE a seat back: had the
        // withdrawn booking been his third, the demotion fired inside
        // _recordArbiterMistake and none of it is walked back. That case is
        // test_VindicationAfterDemotionDoesNotUnderflowTheStreak, and the
        // assertion above is about this scene, not a general rule.
        assertEq(
            ReputationFacet(address(diamond)).getXP(arbiter), xpAfterHand,
            "XP is deliberately not restored, but neither is it slashed twice"
        );
    }

    /// The underflow the subtraction has to survive, and it is a real path
    /// rather than a defensive shrug. If the hand overturn that booked the
    /// mistake was the arbiter's THIRD, _recordArbiterMistake has already reset
    /// the streak to zero and demoted him — and raiseAppeal never asks whether
    /// the arbiter is still seated, so the appeal proceeds and lands on a
    /// counter that has nothing left to subtract.
    ///
    /// ⚠️ Named rather than fixed: vindication returns the COUNTER, not the
    /// seat. A demoted arbiter stays demoted here even though the panel has
    /// just contradicted the mistake that unseated him. Re-seating is a
    /// different decision from arithmetic on a counter, and it is not this
    /// line's to make.
    function test_VindicationAfterDemotionDoesNotUnderflowTheStreak() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();

        // Two mistakes on two other disputes bring him to the threshold's edge.
        _disputeAndOverturn(address(0x7201), address(0x7202), arbiter);
        _disputeAndOverturn(address(0x7203), address(0x7204), arbiter);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 2,
            "setup: two mistakes booked"
        );

        // Third dispute, third mistake.
        //
        // ⚠️ THE SCENE WAS REBUILT WHEN THE AUTOMATIC UNSEATING WAS LED INTO THE
        // COMMON REMOVAL DOOR (18 August 2026), AND THE STATE IT
        // NEEDS IS NOW REACHED ONE STEP LATER. The threshold used to reset the
        // streak and unseat the man in this very call; it now suspends him and
        // lays an accusation in the chain's own name, deliberately KEEPING the
        // counter. Not because the button needs it — the button reads
        // the RECORD and opens at streak 0 — but because the row of mistakes
        // did not end just by being noticed, and the manual door still proves
        // its cause by that number.
        //
        // The property under test is unchanged and still reachable: it is the
        // REMOVAL that zeroes the streak (_performRemoval), so pressing the
        // button produces exactly the state the underflow needs — a booked hand
        // overturn with nothing left in the counter to take back.
        address agr = _disputeToVerdict(address(0x7205), address(0x7206), true);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 3,
            "setup: the threshold keeps the streak; being noticed did not end the row"
        );

        // ⚠️ THE APPEAL IS RAISED BEFORE THE BUTTON, AND IT HAS TO BE. Its
        // window is FINALIZE_DELAY — 24 hours from the VERDICT — while the
        // pause before removal is 48. So "removed, then appealed" is not a
        // reachable order at all; the only way into the state under test is
        // "appealed, then removed, then the panel finishes". Worth stating,
        // because the naive reading of the rebuilt removal path suggests otherwise.
        //
        // The hand flipped clientWins to false, so the client is the loser.
        address cli = address(0x7205);
        usdc.mint(cli, 100 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(cli);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(address(0x7299));
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "setup: the removal spent the evidence it was built on"
        );
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "setup: the chain's own accusation, executed, unseated him"
        );

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);

        // Must not revert on an arithmetic underflow.
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "nothing left to take back, and nothing wrapped around"
        );
    }

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
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
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
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
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

    /// A PANEL THAT VINDICATES TAKES ONE BACK. The arbiter rules, the hand
    /// overturns him (+1), the loser appeals, the panel flips the ruling back
    /// to the ARBITER'S OWN — so in the end his verdict stands, and a mark
    /// against him for this dispute would be the record lying. Same argument
    /// that made the streak give one back when that rule was first written.
    function test_PanelVindicationTakesBackOneOverturn() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();

        // One overturn on ANOTHER dispute first: it must survive untouched.
        // Subtracting the whole count here would erase mistakes the panel said
        // nothing about.
        _disputeAndOverturn(address(0x7501), address(0x7502), arbiter);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter), 1,
            "setup: one overturn on an unrelated dispute"
        );

        address agr = _disputeToVerdict(address(0x7503), address(0x7504), true);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter), 2,
            "setup: the hand booked the second"
        );

        // The hand flipped clientWins to false, so the client is the loser and
        // the one who may appeal.
        address cli = address(0x7503);
        usdc.mint(cli, 100 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(cli);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr).clientWins,
            "scene is not the one: the panel must have restored the arbiter's ruling"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter), 1,
            "ONE taken back, and only one: the other dispute is still his"
        );
    }

    /// The floor under that subtraction. ⚠️ CORRECTED IN REVIEW ROUND 1: the
    /// first version of this docstring called the path "live", and it is not.
    /// After the cut every +1 has a strictly earlier +1 behind it, and nothing
    /// zeroes the field. The migration window — overturned before the cut,
    /// appealed after — needs raiseAppeal, which needs four arbiters, and the
    /// chain has one.
    ///
    /// The scene stays anyway, and not out of habit: without the guard 0 − 1
    /// wraps to 2²⁵⁶−1 and stands in a permanent record as this arbiter's
    /// overturn count. A cheap check against an expensive lie.
    ///
    /// Seeded with vm.store because that history cannot be replayed on a fresh
    /// stand — the increment is in the same transaction as the overturn.
    function test_VindicationCannotUnderflowTheOverturnCount() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();

        address agr = _disputeToVerdict(address(0x7601), address(0x7602), true);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);

        // Wind the counter back to the state a pre-cut overturn leaves: the
        // hand's booking never happened, because the field did not exist.
        vm.store(
            address(diamond),
            keccak256(abi.encode(arbiter, uint256(ARB_STORAGE_BASE) + SLOT_OVERTURNED_VERDICTS)),
            bytes32(uint256(0))
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter), 0,
            "setup: nothing in the counter, exactly as on the day of the cut"
        );

        address cli = address(0x7601);
        usdc.mint(cli, 100 * 10**6);
        vm.prank(cli);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(cli);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);

        // Must not revert on an arithmetic underflow.
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter), 0,
            "nothing left to take back, and nothing wrapped around"
        );
        // Said as its own assertion rather than left to the reader of a zero:
        // the failure this guards is not a revert, it is a plausible-looking
        // enormous number in a permanent record.
        assertLt(
            ArbiterAccountabilityFacet(address(diamond)).getOverturnedVerdicts(arbiter),
            type(uint256).max,
            "an unguarded subtraction would have wrapped, not reverted"
        );
    }

    function testResolveAppeal_UpholdForfeitsDepositNoPenalty() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        uint256 vaultBefore = ArbiterRegistryFacet(address(diamond)).getVaultBalance();

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore + 20 * 10**6);
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0);

        // Original verdict stands — client (winner) gets paid at finalization.
        vm.warp(block.timestamp + 24 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        assertEq(uint8(Agreement(agr).status()), uint8(Agreement.Status.RESOLVED));
    }

    // Tie vote (2 overturn vs. 2 uphold) at/above quorum must resolve to UPHOLD, not overturn,
    // since resolveAppeal() uses strict `>` (votesOverturn > votesUphold) to decide overturn.
    // Requires a 4th eligible voter beyond the 3 from _addAppealQuorumArbiters(), since the
    // ruling arbiter can't vote on its own verdict and 3 eligible voters can never tie.
    function testResolveAppeal_TiedVoteUpholdsNotOverturn() public {
        (address a2, address a3, address a4) = _addAppealQuorumArbiters();
        address a5 = address(0x33);
        ArbiterRegistryFacet(address(diamond)).addArbiter(a5);

        address agr = _disputeToVerdict(client, executor, true); // client wins, executor loses

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        uint256 vaultBefore = ArbiterRegistryFacet(address(diamond)).getVaultBalance();

        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn
        vm.prank(a3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true); // overturn
        vm.prank(a4);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold
        vm.prank(a5);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false); // uphold

        // Confirm the tally really is a 2-vs-2 tie before resolving.
        (uint256 uphold, uint256 overturnVotes) = ArbiterRegistryFacet(address(diamond)).getAppealVotes(agr);
        assertEq(uphold, 2);
        assertEq(overturnVotes, 2);

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        // Tie at quorum -> uphold path taken: deposit forfeited to the vault, ruling arbiter
        // not penalized.
        assertEq(ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore + 20 * 10**6);
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0);

        // Original verdict stands — client (winner) gets paid at finalization, not the executor.
        vm.warp(block.timestamp + 24 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        assertEq(uint8(Agreement(agr).status()), uint8(Agreement.Status.RESOLVED));
    }

    function testResolveAppeal_NoQuorumUpholdsByDefaultAtWindowClose() public {
        (address a2,,) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        uint256 vaultBefore = ArbiterRegistryFacet(address(diamond)).getVaultBalance();

        // Only 1 of 3 needed votes cast — quorum never reached.
        vm.prank(a2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);

        vm.warp(block.timestamp + 4 days + 1); // APPEAL_REVIEW_WINDOW closes

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore + 20 * 10**6);
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0);
    }

    function testResolveAppeal_RevertsBeforeQuorumOrWindowClose() public {
        (address a2,,) = _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

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

    function testAppealUnavailableBelowQuorum_OverturnVerdictStillWorks() public {
        // setUp() registers only the default `arbiter` — no extra arbiters here.
        address agr = _disputeToVerdict(client, executor, true);

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);

        vm.prank(executor);
        vm.expectRevert(ArbiterRegistryFacet.InsufficientArbitersForAppeal.selector);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        // The pre-existing owner/DAO safety valve is untouched.
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1);

        vm.warp(block.timestamp + 24 hours + 1);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        // raiseAppeal reverted before ever pulling the deposit (the quorum check runs
        // before transferFrom) — executor keeps the full 100 USDC mint, plus the payout.
        assertEq(usdc.balanceOf(executor), 100 * 10**6 + AMOUNT);
    }

    // Final-review Finding A: owner's overturnVerdict() and unfreezeVerdict() must not be
    // usable while an appeal is actively in progress (appealed=true, appealResolved=false) —
    // otherwise overturnVerdict could double-slash the same arbiter on top of resolveAppeal,
    // and unfreezeVerdict could let finalizeVerdict bypass the in-flight vote entirely.
    //
    // ⚠️ HALF OF THAT RATIONALE HAS SINCE MOVED (18 August 2026, on review of the
    // one-mistake-per-verdict gate).
    // The double-slash is now impossible with or without this guard: a hand press would
    // set `overturned`, and resolveAppeal then books nothing and takes the press's booking
    // back. What still rests on this guard is the OTHER half — a hand must not pre-empt a
    // vote that is running. The guard is kept for that, and the test below is unchanged.
    function testOverturnVerdict_RevertsDuringActiveAppeal() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // client wins, executor loses

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.expectRevert(ArbiterRegistryFacet.AppealInProgress.selector);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);
    }

    function testUnfreezeVerdict_RevertsDuringActiveAppeal() public {
        _addAppealQuorumArbiters();
        address agr = _disputeToVerdict(client, executor, true); // client wins, executor loses

        usdc.mint(executor, 100 * 10**6);
        vm.prank(executor);
        usdc.approve(address(diamond), 20 * 10**6);
        vm.prank(executor);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        // Owner (test contract) attempts to unfreeze mid-appeal — must revert, not bypass
        // the in-progress vote.
        vm.expectRevert(ArbiterRegistryFacet.AppealInProgress.selector);
        ArbiterRegistryFacet(address(diamond)).unfreezeVerdict(agr);
    }

    // Sanity check: unfreezeVerdict() still works fine outside of any appeal (the guard only
    // fires when appealed && !appealResolved — freezeVerdict()'s own standalone use, with no
    // appeal ever raised, must be unaffected).
    function testUnfreezeVerdict_WorksWithNoAppealInProgress() public {
        address agr = _disputeToVerdict(client, executor, true);

        ArbiterRegistryFacet(address(diamond)).freezeVerdict(agr);
        ArbiterRegistryStorage.PendingVerdict memory frozen = ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr);
        assertTrue(frozen.frozen);

        ArbiterRegistryFacet(address(diamond)).unfreezeVerdict(agr);
        ArbiterRegistryStorage.PendingVerdict memory unfrozen = ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agr);
        assertFalse(unfrozen.frozen);
    }
}