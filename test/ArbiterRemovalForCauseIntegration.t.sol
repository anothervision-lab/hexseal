// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Removal for cause — BY THE PRODUCTION PATH, on a real diamond.
//
// test/ArbiterRemovalForCause.t.sol deploys ArbiterAccountabilityFacet ON ITS OWN
// and drives the state to the threshold with vm.store — fast, but it does not prove
// that the production contract can produce that state itself. A review found
// exactly such a case: tests with the streak set directly stayed green for a
// threshold that _recordArbiterMistake never leaves behind it — the scene lived in
// the test and did not exist in production.
//
// This file builds a FULL diamond (all 12 production facets, with DeployFull's own
// builders — the same way test/DeployFullSelectors.t.sol uses for its own
// end-to-end check) and drives the judging-mistake counter to the threshold with
// REAL overturnVerdict calls, through the genuine cycle deployAgreement → fund →
// activate → raiseDispute → claimDispute → submitVerdict → overturnVerdict (the
// device comes from test/Diamond.t.sol::_disputeAndOverturn).
//
// Removal from arbiterList belongs here too: it is readable only through
// ArbiterRegistryFacet.getArbiters(), which the light ArbiterAccountabilityFacet
// bench does not have — here it does, because this is a real diamond.
//
// test_WholeChain... below is the "whole chain" case. It and it alone proves that a
// way out of the "earned DAO with a zero successor" trap exists IN FACT:
// setDAOAddress names the first successor AFTER the DAO is already active by the
// earned road (not through activateDAO()), and that same successor then really
// carries out a removal for cause through removeArbiterForCause. It lives here and
// not on the light bench test/ArbiterSeatingHandover.t.sol: it needs BOTH facets on
// one storage — setDAOAddress (ArbiterRegistryFacet) and removeArbiterForCause
// (ArbiterAccountabilityFacet).

import "forge-std/Test.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";
import "../src/DiamondProxy.sol";
import "../src/RegistryFacet.sol";
import "../src/FactoryFacet.sol";
import "../src/AgreementDeployer.sol";
import "../src/Agreement.sol";
import "../src/facets/JobBoardFacet.sol";
import "../src/facets/ServiceBoardFacet.sol";
import "../src/facets/ArbiterRegistryFacet.sol";
import "../src/facets/ArbiterAccountabilityFacet.sol";
import "../src/facets/ArbiterApplicationsFacet.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import "../script/DeployFull.s.sol";

contract MockUSDCIntegration {
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

contract ArbiterRemovalForCauseIntegrationTest is Test {
    DiamondProxy diamond;
    DeployFull deploy;
    MockUSDCIntegration usdc;

    address owner;
    address feeRecipient;
    address arbiter;

    uint256 constant AMOUNT = 100 * 10 ** 6;
    uint256 constant DEADLINE = 7;
    string constant TERMS = "test terms";
    bytes32 constant DISPUTE_SALT = bytes32("removal-integration-salt");

    /// ReputationStorage.POSITION — see src/facets/ReputationFacet.sol.
    /// uniqueActiveUsers is slot 8, obtained by sweeping in
    /// test/ArbiterRemovalForCause.t.sol; the same slot, the same method, and it is
    /// not rediscovered here.
    bytes32 constant REP_BASE = 0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400;
    uint256 constant SLOT_UNIQUE_ACTIVE_USERS = 8;

    /// The automatic-removal codes in the getArbiterStanding card.
    ///
    /// ⚠️ LITERALS ON PURPOSE, and not `AUTO_REMOVAL_BASE + uint8(DemotionPath.X)`:
    /// an expression over a library constant and an enum value derives the
    /// expectation from the thing under test — shift the base or permute the enum and
    /// both sides of the comparison move together while the lock stays silent. Here
    /// the expectation is taken from outside the code: 252 is 'the path is not
    /// named', 253 an overturn, 254 a timeout, 255 the votes.
    uint8 constant AUTO_OVERTURN = 253;
    uint8 constant AUTO_TIMEOUT  = 254;
    uint8 constant AUTO_APPEAL   = 255;

    /// ArbiterRegistryStorage.POSITION — the same namespace test/ArbiterSuspension.t.sol
    /// reads (ARB_BASE is there too), and the bond slot 12 was obtained there by
    /// sweeping. It is needed here for exactly one thing: so that 'the bond burns ON
    /// THE REMOVAL and not on the accusation' is checked on a non-zero bond. The
    /// bench seats the base arbiter by hand (addArbiter), and a hand seating takes no
    /// bond at all — see test_HandSeatedArbiterHasNoBondToBurn.
    bytes32 constant ARB_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;
    uint256 constant SLOT_ARBITER_BOND = 12;

    /// An outsider: no role at all, neither arbiter nor chief nor owner.
    address constant STRANGER = address(0x5A);
    /// The chief. The same address the scenes below already use.
    address constant CHIEF = address(0xC4);
    bytes32 constant DIGEST = keccak256("the evidence, attested not verified");

    function setUp() public {
        owner = address(this);
        feeRecipient = address(0x4);
        arbiter = address(0x3);

        usdc = new MockUSDCIntegration();
        deploy = new DeployFull();

        DiamondCutFacet cutFacet     = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownFacet      = new OwnershipFacet();
        RegistryFacet regFacet       = new RegistryFacet();
        FactoryFacet facFacet        = new FactoryFacet();
        JobBoardFacet jobBoard       = new JobBoardFacet();
        ServiceBoardFacet serviceBoard = new ServiceBoardFacet();
        ArbiterRegistryFacet arbiterFacet = new ArbiterRegistryFacet();
        ArbiterAccountabilityFacet accFacet = new ArbiterAccountabilityFacet();
        ArbiterApplicationsFacet appFacet = new ArbiterApplicationsFacet();
        DealMetadataFacet metaFacet  = new DealMetadataFacet();
        JobReceiptFacet receiptFacet = new JobReceiptFacet();
        ReputationFacet repFacet     = new ReputationFacet();

        IDiamondCut.FacetCut[] memory initCuts = deploy.buildInitCuts(
            address(cutFacet), address(loupeFacet), address(ownFacet), address(regFacet), address(facFacet)
        );
        diamond = new DiamondProxy(owner, initCuts, address(0), "");

        IDiamondCut.FacetCut[] memory remainingCuts = deploy.buildRemainingCuts(
            address(jobBoard), address(serviceBoard), address(arbiterFacet), address(accFacet),
            address(appFacet), address(metaFacet), address(receiptFacet), address(repFacet)
        );
        IDiamondCut(address(diamond)).diamondCut(remainingCuts, address(0), "");

        RegistryFacet(address(diamond)).initRegistry(address(diamond));

        Agreement agreementImpl = new Agreement();
        AgreementDeployer agDeployer = new AgreementDeployer(address(diamond), address(agreementImpl));
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0xDEAD), address(diamond), address(agDeployer)
        );

        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
    }

    // ── Helpers (moved from test/Diamond.t.sol with minimal edits) ──

    function _claimDisputeAs(address agreementAddr, address arbiterAddr) internal {
        bytes32 commitment = keccak256(abi.encodePacked(agreementAddr, arbiterAddr, DISPUTE_SALT));
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).commitDisputeClaim(commitment);
        vm.roll(block.number + 1);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).claimDispute(
            agreementAddr, DISPUTE_SALT, bytes32(uint256(0xB0)), bytes32(uint256(0x51))
        );
    }

    /// One full cycle: a new client/executor pair (so as not to run into
    /// ActiveDealExists), a dispute, a claim, a verdict, an overturn by the owner.
    /// After each call arbiterMistakeStreak[arbiter] grows by one — BY THE LIVE road,
    /// not by vm.store.
    function _disputeAndOverturn(address cli, address exec) internal returns (address agreementAddr) {
        usdc.mint(cli, 1_000_000 * 10 ** 6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10 ** 6);
        vm.prank(address(diamond));
        agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, exec, arbiter, AMOUNT, DEADLINE, TERMS, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(exec);
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDisputeAs(agreementAddr, arbiter);

        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreementAddr, true);

        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agreementAddr, false);
    }

    function _setUniqueActiveUsers(uint256 n) internal {
        vm.store(address(diamond), bytes32(uint256(REP_BASE) + SLOT_UNIQUE_ACTIVE_USERS), bytes32(n));
    }
    /// Words the stand puts on a proposal. The causes used here are the ones
    /// the chain does not check, and those demand both a digest and words.
    string constant PROPOSAL_WORDS = "the accusation, stated once, on the proposal";

    /// Since 17 August 2026 a removal only runs through a proposal that has
    /// sat for REMOVAL_DELAY, and the cause at execution must match the one
    /// proposed. The helper lays the proposal down and winds time to the far
    /// side of the pause — the diamond twin of _proposeAndWait in
    /// test/ArbiterRemovalForCause.t.sol.
    ///
    /// ⚠️ vm.getBlockTimestamp(), not block.timestamp: under via_ir solc treats
    /// TIMESTAMP as constant within a call.
    ///
    /// ⚠️ LAID DOWN BY THE OWNER, AND THAT WORKS ONLY BEFORE THE HANDOVER.
    /// This paragraph used to say the opposite of what the branch is for: "the
    /// owner goes through whether or not governance is active — only the
    /// EXECUTION moves to daoAddress". Both halves are wrong since review round
    /// 2 of the pause (17 August 2026): the accusation door travelled with the
    /// right to act on it, and proposeRemoval answers the former owner with
    /// RemovalHandedOver.
    ///
    /// So this helper is a BEFORE-HANDOVER helper and nothing else. Past the
    /// handover use `_proposeAndWaitAs(successor, ...)`, which exists for
    /// exactly that and is what every scene past a handover already calls.
    function _proposeAndWait(address who, ArbiterAccountabilityFacet.Cause cause, bytes32 digest)
        internal
    {
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(who, cause, digest, PROPOSAL_WORDS);
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
    }

    /// Same, laid down by a named caller. Needed past handover: since
    /// 17 August 2026 the accusation door travels with the right to
    /// act on it, so the OWNER cannot propose once a successor is named — the
    /// successor lays his own, which is what a handover is for.
    function _proposeAndWaitAs(
        address caller,
        address who,
        ArbiterAccountabilityFacet.Cause cause,
        bytes32 digest
    ) internal {
        vm.prank(caller);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(who, cause, digest, PROPOSAL_WORDS);
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
    }

    /// THREE DIFFERENT DISPUTES, not one three times. `AlreadyOverturned` forbade
    /// striking the same verdict twice, and that is exactly the price it was made
    /// for: before it the automatic road cost ONE submitted verdict and three calls
    /// in one block.
    function _threeOverturnsOnDistinctDisputes(address judged) internal {
        require(judged == arbiter, "stand builds disputes for the seated arbiter only");
        _disputeAndOverturn(address(0x9A1), address(0x9A2));
        _disputeAndOverturn(address(0x9A3), address(0x9A4));
        _disputeAndOverturn(address(0x9A5), address(0x9A6));
    }

    /// The right of removal moves to the named successor. After that the owner
    /// neither proposes nor removes: the ratchet the whole branch exists for.
    ///
    /// ⚠️ THE EARNED ROAD IS GONE. "By the threshold, as in life, and not by a manual
    /// activateDAO()" used to stand here — and that was inverted: the threshold
    /// switches NOTHING on by itself, it became a condition of switching on by hand.
    /// The handover now costs three doors and none of them can be bypassed: an earned
    /// corps, the owner's proposal, and confirmation by the successor themselves.
    function _handOverRemovalRight(address dao) internal {
        _setUniqueActiveUsers(ArbiterRegistryFacet(address(diamond)).getDaoThreshold());
        ArbiterRegistryFacet(address(diamond)).setDAOAddress(dao);
        vm.prank(dao);
        ArbiterRegistryFacet(address(diamond)).acceptDAOAddress();
        ArbiterRegistryFacet(address(diamond)).activateDAO();
    }

    /// Puts a bond on an arbiter straight into storage. Through applyAsArbiter it
    /// will not work: that requires an active DAO, and an active DAO closes half the
    /// scenes below.
    function _giveBond(address who, uint256 amount) internal {
        vm.store(
            address(diamond),
            keccak256(abi.encode(who, uint256(ARB_BASE) + SLOT_ARBITER_BOND)),
            bytes32(amount)
        );
    }


    // ── Reachability by the production road ──

    /// MISTAKE_THRESHOLD = 2 (MAX_ARBITER_MISTAKES − 1, see
    /// ArbiterAccountabilityFacet). Two REAL overturnVerdict calls bring
    /// arbiterMistakeStreak to 2, the arbiter stays registered (the demotion fires
    /// only on the third, in _recordArbiterMistake), and
    /// removeArbiterForCause(OverturnedVerdicts) must go through — the state was
    /// produced by the production contract, not by a test's vm.store.
    function test_OverturnedVerdictsIsReachableThroughRealPath() public {
        _disputeAndOverturn(address(0x101), address(0x102));
        _disputeAndOverturn(address(0x103), address(0x104));

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 2,
            "two real overturns must bring the counter to the threshold"
        );
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "at the threshold the demotion has not fired yet: the arbiter is alive"
        );

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0),
            ""
        );

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "a removal on a cause reached by the production path must go through"
        );
    }

    // ── Removal from arbiterList ──

    function test_RemovalForCausePrunesArbiterList() public {
        address second = address(0x33);
        ArbiterRegistryFacet(address(diamond)).addArbiter(second);
        assertEq(ArbiterRegistryFacet(address(diamond)).getArbiters().length, 2);

        _disputeAndOverturn(address(0x201), address(0x202));
        _disputeAndOverturn(address(0x203), address(0x204));

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0),
            ""
        );

        address[] memory list = ArbiterRegistryFacet(address(diamond)).getArbiters();
        assertEq(list.length, 1, "the removed one must disappear from arbiterList and not only from isArbiter");
        assertEq(list[0], second, "the arbiter left is the one who was not removed");
    }

    // ── The whole chain ──

    /// The threshold is earned → the owner PROPOSES a successor → they confirm
    /// themselves → the owner switches governance on → that same successor really
    /// carries out a removal for cause. The whole chain, all four doors in a row.
    ///
    /// ⚠️ REWRITTEN ON 26 AUGUST 2026. The earlier version began with "the DAO is
    /// active by the earned road and there is no successor yet" — a state that no
    /// longer exists: the threshold switches nothing on by itself, and `activateDAO()`
    /// requires an ALREADY CONFIRMED successor. The "orphaned corps" trap the test
    /// was written for is now closed not by a clause in the ratchet but by the fact
    /// that governance cannot be switched on without a live successor at all.
    function test_WholeChainThresholdThenProposalThenAcceptanceThenRealRemoval() public {
        _setUniqueActiveUsers(ArbiterRegistryFacet(address(diamond)).getDaoThreshold());
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isDaoActive(),
            "the threshold on its own does not switch governance on"
        );
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getDAOAddress(), address(0),
            "setup: there is no successor yet"
        );

        address dao = address(0xDA0);
        ArbiterRegistryFacet(address(diamond)).setDAOAddress(dao);
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getDAOAddress(), address(0),
            "a proposal does not confer rights yet"
        );
        vm.prank(dao);
        ArbiterRegistryFacet(address(diamond)).acceptDAOAddress();
        ArbiterRegistryFacet(address(diamond)).activateDAO();
        assertEq(ArbiterRegistryFacet(address(diamond)).getDAOAddress(), dao);

        _disputeAndOverturn(address(0x301), address(0x302));
        _disputeAndOverturn(address(0x303), address(0x304));
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));

        // The successor lays his own accusation: past handover the owner
        // cannot, since the door travels with the right (17 August 2026).
        _proposeAndWaitAs(dao, arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0));
        vm.prank(dao);
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0),
            ""
        );

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "a successor appointed out of the orphaned state really did remove an arbiter"
        );
    }

    // ── What a review found on the proposal door ──
    //
    // A proposal must disappear in ALL THREE exits from the corps, not only in
    // removeArbiterForCause. It is checked here and not on the light bench — both
    // facets must share ONE real storage, and resignAsArbiter and the automatic
    // demotion must really execute rather than be simulated with vm.store.
    //
    // resignAsArbiter must refuse while a live proposal hangs against the caller —
    // otherwise a forewarned arbiter reads the public record and leaves of their own
    // accord in one transaction, taking the whole bond with them.

    /// A fresh arbiter with no open claims — so that resignAsArbiter does not run
    /// into anything extraneous (openClaimCount, a suspension), and the only variable
    /// in the test is the proposal.
    function _addFreshArbiter(address who) internal {
        ArbiterRegistryFacet(address(diamond)).addArbiter(who);
    }

    function test_ResignRevertsWhileProposalLive() public {
        address who = address(0x55);
        _addFreshArbiter(who);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );

        vm.prank(who);
        vm.expectRevert(ArbiterRegistryFacet.HasLiveRemovalProposal.selector);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
    }

    /// The lower boundary: a second before the end of the TTL the proposal is still
    /// alive and the door is still locked. Symmetrical to the suspension's
    /// test_SuspensionHoldsUntilTheLastSecond.
    function test_ResignHoldsUntilTheLastSecondOfProposal() public {
        address who = address(0x56);
        _addFreshArbiter(who);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );

        uint256 ttl = ArbiterAccountabilityFacet(address(diamond)).getProposalTTL();
        vm.warp(vm.getBlockTimestamp() + ttl - 1);

        vm.prank(who);
        vm.expectRevert(ArbiterRegistryFacet.HasLiveRemovalProposal.selector);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
    }

    /// The upper boundary: exactly the TTL and it is stale, the door open.
    ///
    /// ⚠️ THIS PAIR NO LONGER PROVES THE MIRROR IS EQUAL, and saying so matters more
    /// than keeping the earlier wording. The term now lies IN THE RECORD, and it is
    /// put there by the accountability facet out of its own constant — which means
    /// both halves read ONE number from storage and cannot diverge on a new record,
    /// structurally. The `PROPOSAL_TTL_MIRROR` mirror remains the answer to exactly
    /// one case — a record with a zero `ttl`, made before that change — and
    /// test_LegacyProposalIsJudgedByTheSameClockInBothFacets below guards it.
    function test_ResignSucceedsAfterProposalExpires() public {
        address who = address(0x57);
        _addFreshArbiter(who);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );

        uint256 ttl = ArbiterAccountabilityFacet(address(diamond)).getProposalTTL();
        vm.warp(vm.getBlockTimestamp() + ttl);

        vm.prank(who);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(who));
    }

    /// A RECORD WITH NO TERM IS THE ONLY THING STILL JUDGED BY THE MIRROR, AND BOTH
    /// HALVES MUST ANSWER ABOUT IT ALIKE.
    ///
    /// Such records are not hypothetical: they were left by facets that stood on
    /// chain before that change. Their `ttl` is zero, and each half then takes ITS OWN
    /// constant — the registry `PROPOSAL_TTL_MIRROR`, the accountability facet
    /// `PROPOSAL_TTL`. Let them diverge by a second and a person would see the
    /// accusation alive in the feed while the resignation door was already open (or
    /// the other way round).
    ///
    /// The scene stands here and not on the light bench precisely because it is a
    /// SEAM: `hasLiveProposal` belongs to one facet and `resignAsArbiter` to another,
    /// while their storage is shared. Both are asked on ONE AND THE SAME second, on
    /// either side of the boundary.
    function test_LegacyProposalIsJudgedByTheSameClockInBothFacets() public {
        address who = address(0x58);
        _addFreshArbiter(who);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );
        (, , uint256 proposedAt, ,) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(who);
        _clearProposalTtl(who);

        uint256 ttl = ArbiterAccountabilityFacet(address(diamond)).getProposalTTL();

        // A second BEFORE the boundary: alive for one, locked for the other.
        vm.warp(proposedAt + ttl - 1);
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(who),
            "the accountability facet: a second before the edge the accusation is alive"
        );
        vm.prank(who);
        vm.expectRevert(ArbiterRegistryFacet.HasLiveRemovalProposal.selector);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();

        // Exactly AT the boundary: stale for one, open for the other.
        vm.warp(proposedAt + ttl);
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(who),
            "the accountability facet: exactly at the edge the accusation has gone stale"
        );
        vm.prank(who);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(who));
    }

    /// ⚠️ A MEASUREMENT SHOWED AN EMPTY PLACE HERE, AND THIS TEST CLOSES IT.
    /// The corruption "let the registry read its own constant instead of the record"
    /// (_hasLiveProposalHere) gave ZERO red out of 1276: BOTH halves read the term
    /// from the record, and only one was checked. A classic dead lock — the fix
    /// exists and nobody uses it.
    ///
    /// The registry's observable door is resignation: it is locked WHILE the
    /// accusation is alive, and whether it is alive the registry judges itself, with
    /// its own helper, rather than by calling its neighbour. Both halves are asked on
    /// one second, on either side of the boundary, about a record with A FOREIGN term
    /// — the very state a cut that changed the constant would have left behind.
    function test_ARuleFrozenLongerThanTodaysKeepsBothDoorsShut() public {
        address who = address(0x59);
        _addFreshArbiter(who);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );
        (, , uint256 proposedAt, ,) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(who);
        _setProposalTtl(who, uint64(30 days));

        vm.warp(proposedAt + 20 days);
        assertGt(20 days, ArbiterAccountabilityFacet(address(diamond)).getProposalTTL(),
            "setup: by today's constant this day is already past the term");

        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(who),
            "the accountability facet judges by the record"
        );
        vm.prank(who);
        vm.expectRevert(ArbiterRegistryFacet.HasLiveRemovalProposal.selector);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();

        // And symmetrically: a short term in the record opens both doors earlier than
        // today's constant would — otherwise "the record is read" could not be told
        // from "the larger of the two is taken".
        _setProposalTtl(who, uint64(3 days));
        vm.warp(proposedAt + 4 days);
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(who),
            "a short term in the record means a short life for the accusation"
        );
        vm.prank(who);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(who));
    }

    /// An accusation laid down by THE CHAIN must carry the term in the record —
    /// otherwise the next cut that shortens the constant would make it stale in
    /// silence, and the one accused by the chain has neither an author to object to
    /// nor a door to leave by.
    ///
    /// ⚠️ THE ONLY OBSERVABLE DIFFERENCE IS THE VALUE IN STORAGE ITSELF, and that is
    /// said out loud rather than hidden: while the constant has not changed, a record
    /// with its own term and a record with a zero behave IDENTICALLY (a zero falls
    /// into the fallback branch of that same constant). A behavioural scene is
    /// impossible here in principle, so storage is what is checked.
    ///
    /// The expectation is meanwhile taken from ANOTHER facet (`getProposalTTL` is a
    /// constant of the accountability facet), while what is written is put there by
    /// the registry out of its own mirror. Two independent sources: let them diverge
    /// and the test goes red.
    function test_TheChainWritesItsOwnRuleIntoTheAccusationItLays() public {
        _threeOverturnsOnDistinctDisputes(arbiter);
        (, , uint256 proposedAt, address by,) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertGt(proposedAt, 0, "setup: the chain has laid down an accusation");
        assertEq(by, address(0), "setup: the accusation is nobody's, that is, the chain's");

        assertEq(
            _storedProposalTtl(arbiter),
            ArbiterAccountabilityFacet(address(diamond)).getProposalTTL(),
            "the chain must freeze into the record the same term the human door lays down"
        );
    }

    /// The third slot of the `removalProposals[who]` record: `by` in the low twenty
    /// bytes, `ttl` in the next eight.
    function _proposalTtlSlot(address who) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(who, uint256(ARB_BASE) + 29))) + 3);
    }

    function _storedProposalTtl(address who) internal view returns (uint64) {
        return uint64(uint256(vm.load(address(diamond), _proposalTtlSlot(who))) >> 160);
    }

    /// Puts a FOREIGN term into the record — the state a cut that changed the
    /// constant would have left behind. It is checked against its neighbours right
    /// here, see _clearProposalTtl below.
    function _setProposalTtl(address who, uint64 ttl) internal {
        (uint8 causeBefore, bytes32 digestBefore, uint256 atBefore, address byBefore,) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(who);

        bytes32 slot = _proposalTtlSlot(who);
        bytes32 keepBy = vm.load(address(diamond), slot) & bytes32(uint256(type(uint160).max));
        vm.store(address(diamond), slot, keepBy | bytes32(uint256(ttl) << 160));

        (uint8 causeAfter, bytes32 digestAfter, uint256 atAfter, address byAfter,) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(who);
        assertEq(causeAfter,  causeBefore,  "the ttl offset missed: the cause moved");
        assertEq(digestAfter, digestBefore, "the ttl offset missed: the digest moved");
        assertEq(atAfter,     atBefore,     "the ttl offset missed: the time of filing moved");
        assertEq(byAfter,     byBefore,     "the ttl offset missed: the author moved");
        assertEq(_storedProposalTtl(who), ttl, "the ttl offset missed: the record did not change");
    }

    /// Turns a fresh record into a "pre-reform" one: it zeroes `ttl` and leaves
    /// everything else in place. `removalProposals` is slot 29 (a literal in
    /// test/StorageLayout.t.sol), and `ttl` is packed with `by` in the record's third
    /// slot, after the address's low twenty bytes.
    ///
    /// It is checked right here: the neighbouring fields must stay as they were. Miss
    /// the offset and either a neighbour changes (visible here) or nothing changes at
    /// all (and the scene above would then fail to go red for its own reason).
    function _clearProposalTtl(address who) internal {
        (uint8 causeBefore, bytes32 digestBefore, uint256 atBefore, address byBefore,) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(who);

        bytes32 slot = _proposalTtlSlot(who);
        bytes32 packed = vm.load(address(diamond), slot);
        vm.store(address(diamond), slot, packed & bytes32(uint256(type(uint160).max)));

        (uint8 causeAfter, bytes32 digestAfter, uint256 atAfter, address byAfter,) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(who);
        assertEq(causeAfter,  causeBefore,  "the ttl offset missed: the cause moved");
        assertEq(digestAfter, digestBefore, "the ttl offset missed: the digest moved");
        assertEq(atAfter,     atBefore,     "the ttl offset missed: the time of filing moved");
        assertEq(byAfter,     byBefore,     "the ttl offset missed: the author moved");
    }

    /// On a production diamond: an accusation is no longer extended IN PLACE, and so
    /// the window in which an arbiter leaves with their bond does arrive. The scene
    /// stands here and not on the light bench because it is about the SEAM between
    /// two facets on one storage: the gate lives in
    /// ArbiterAccountabilityFacet.proposeRemoval and the door it locks is
    /// ArbiterRegistryFacet.resignAsArbiter. The light bench deploys only one facet
    /// and does not see the second half at all.
    ///
    /// Before the fix an accuser laid a second proposal a second before it went
    /// stale, in one transaction and without a trace — and that window never arrived.
    ///
    /// ⚠️ WHAT THIS SCENE DOES NOT PROVE: extension as such is alive. The holder of
    /// the right may withdraw and lay it again, and then resignation is locked once
    /// more — of the four measured harms of an overwrite, three were removed and the
    /// fourth became LOUD rather than impossible: every extension now costs a separate
    /// transaction and leaves a RemovalProposalWithdrawn in the feed. There is no rate
    /// limit of "no more often than once in N" and none was intended.
    function test_ProposalCannotBeRenewedInPlaceAndTheBondGoesFreeAtTTL() public {
        address who = address(0x5A);
        _addFreshArbiter(who);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), PROPOSAL_WORDS
        );
        (, , uint256 proposedAt, , ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(who);

        uint256 ttl = ArbiterAccountabilityFacet(address(diamond)).getProposalTTL();
        vm.warp(proposedAt + ttl - 1); // the last second at which an extension would still have made sense

        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterAccountabilityFacet.ProposalAlreadyLive.selector, address(this), proposedAt
            )
        );
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"), PROPOSAL_WORDS
        );

        // And exactly at the boundary the bond stops being a hostage — provided the
        // accuser did not withdraw and lay it again: that road is alive, it is simply
        // no longer silent (see the ⚠️ in the docstring).
        vm.warp(proposedAt + ttl);
        vm.prank(who);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(who),
            "the accusation went stale and was not extended: the person left of their own accord"
        );
    }

    function test_ResignSucceedsAfterProposalWithdrawn() public {
        address who = address(0x58);
        _addFreshArbiter(who);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(who);

        vm.prank(who);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(who));
    }

    /// Door number two (resignAsArbiter): the proposal must disappear ENTIRELY and
    /// not merely go stale. A stale-but-not-erased record is told from an erased one
    /// only by a raw read of getRemovalProposal (hasLiveProposal answers false in both
    /// cases) — before the clearSeat fix the record would have outlived the departure
    /// and hung with `proposedAt != 0` forever against a person who is already gone
    /// and cannot take it off themselves.
    function test_ResignClearsStaleProposalRecord() public {
        address who = address(0x59);
        _addFreshArbiter(who);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Leak, keccak256("x"),
            "published the chat log of a dispute to a third party"
        );

        uint256 ttl = ArbiterAccountabilityFacet(address(diamond)).getProposalTTL();
        vm.warp(vm.getBlockTimestamp() + ttl); // stale, but not erased yet

        (, , uint256 proposedAtBefore, , ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(who);
        assertTrue(proposedAtBefore != 0, "setup: the stale record is still physically in place");

        vm.prank(who);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();

        (, , uint256 proposedAtAfter, , ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(who);
        assertEq(proposedAtAfter, 0, "resignAsArbiter must erase the record and not merely outlive its going stale");
    }

    /// Door number three: the automatic road must erase the proposal by the same road
    /// as a manual removal — through clearSeat.
    ///
    /// ⚠️ THE SCENE WAS REBUILT. The earlier one laid a human proposal and expected
    /// three overturns to erase it along with the seat. That NO LONGER HAPPENS: a live
    /// human accusation is an occupied door, the chain yields to it silently
    /// (otherwise the revert would be swallowed by an empty try/catch in Agreement),
    /// and that case is checked by a separate scene,
    /// test_ChainYieldsToALiveHumanProposalWithoutReverting.
    ///
    /// The property under test stayed the same and moved to the door that is now the
    /// third one: the chain's accusation is cleared BY THE REMOVAL rather than hanging
    /// after it — otherwise hasLiveProposal would answer true for up to two weeks
    /// against a person who is no longer in the registry and who cannot take a record
    /// about themselves off.
    function test_ChainRemovalClearsTheProposal() public {
        _threeOverturnsOnDistinctDisputes(arbiter);
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "setup: the chain's accusation is alive"
        );

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "setup: the removal happened"
        );

        (, , uint256 proposedAtAfter, , ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertEq(proposedAtAfter, 0, "a removal must erase the proposal by the same road as the manual one");
    }

    // ============================================================
    //  RETURNING A REMOVED ARBITER
    //
    //  addArbiter does not look at history (only !isDaoActive() and
    //  !d.isArbiter[arbiter]) — the owner brings a removed arbiter back with one
    //  command, and that is the production road for repairing a mistaken removal, not
    //  a hypothetical one. Without clearing removedAt/removalReply, a second
    //  accusation against the same address either stays unanswered forever
    //  (AlreadyAnswered on an empty place) or a serving, not yet removed arbiter can
    //  answer a long-closed accusation. It lives here and not on the light bench:
    //  addArbiter is a function of ArbiterRegistryFacet and respondToRemoval of
    //  ArbiterAccountabilityFacet, and both need ONE real storage behind one diamond.
    // ============================================================

    /// Cause.Collusion and not OverturnedVerdicts — it removes the dependence on the
    /// streak threshold and on the dispute cycle, and the only variable in the test is
    /// the seating and removal themselves.
    function test_ReseatingClearsRemovedAtPreventingPhantomAnswer() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));

        // The owner repairs a mistaken removal — a real road, not a hypothetical one.
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));

        vm.prank(arbiter);
        vm.expectRevert(ArbiterAccountabilityFacet.NothingToAnswer.selector);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(keccak256("late"), "");
    }

    /// The symmetrical half: answered the first removal, was brought back, removed
    /// AGAIN — the second reply must go through rather than run into AlreadyAnswered
    /// from the first. It isolates the removalReply half of clearRemovalRecord from
    /// the removedAt half (the previous test).
    function test_ReseatingAndReremovalAllowsAnsweringAgain() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("first evidence"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("first evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        vm.prank(arbiter);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(keccak256("first answer"), "");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(arbiter),
            keccak256("first answer"),
            "setup: the first reply landed"
        );

        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("second evidence"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("second evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        vm.prank(arbiter);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(keccak256("second answer"), "");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(arbiter),
            keccak256("second answer"),
            "the second reply must land on top of the erased first one rather than revert AlreadyAnswered"
        );
    }

    // ============================================================
    //  THE AUTOMATIC ROAD GIVES THE RIGHT OF REPLY TOO
    //
    //  The owner's decision: the rule sounds in one sentence — "you were removed, so
    //  you may answer" — regardless of who pressed. The ArbiterDemoted public record
    //  is eternal exactly as ArbiterRemovedForCause is.
    //
    //  ⚠️ Removal later moved into the common door, and `removedAt` is now set only by
    //  a removal. A second reply door was then added: a live proposal. So the right of
    //  reply is opened ALREADY BY THE THIRD MISTAKE — together with the suspension and
    //  the accusation — and this test plays the second half: a removal opens it too,
    //  and somebody who stayed silent during the pause does not lose their word. The
    //  first half is played by test_TheChainAccusedAnswersDuringThePause below.
    // ============================================================

    function test_AutoDemotedArbiterCanAnswer() public {
        _threeOverturnsOnDistinctDisputes(arbiter);

        // What is checked here is the `removedAt` door, so the button is pressed:
        // before it there is no removal mark. That the accused could have answered
        // EARLIER, from the third mistake onwards, is a separate scene
        // (test_TheChainAccusedAnswersDuringThePause), and deliberately a different
        // one: this one must go red from a breakage of the `removedAt` half and not
        // from a breakage of the "live proposal" half.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "setup: the chain's accusation reached a removal"
        );

        bytes32 reply = keccak256("I was demoted automatically, here is my account");
        vm.prank(arbiter);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(reply, "");

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(arbiter),
            reply,
            "the automatic road also gives the right of reply: the same public record, the same reply"
        );
    }

    // ============================================================
    //  A WORD BEFORE THE SENTENCE, FOR THE ONE ACCUSED BY THE CHAIN
    //
    //  The automatic removal moved into the common door: a third judging mistake
    //  suspends and ACCUSES rather than removing. So on that road removedAt is not set
    //  at all — and before this fix the one accused by the chain could not answer in
    //  any way, neither during the pause nor after it, until somebody pressed the
    //  button.
    //
    //  They are also the only accused whose accuser is nameless: `by` is zero, there
    //  are no words in the accusation, and the cause is the overturns themselves. And
    //  they are the only one whom the accusation additionally SUSPENDS: a human
    //  proposal does not stop them working, this does. Over two days of pause a reply
    //  is literally the only thing they can do on chain.
    //
    //  The scenes live here and not on the light bench: the chain's accusation is laid
    //  down by ArbiterRegistryFacet._recordArbiterMistake, while the reply goes through
    //  ArbiterAccountabilityFacet — both need one real storage behind one diamond.
    // ============================================================

    /// The main case: the one accused BY THE CHAIN answers during the pause, still
    /// sitting in the corps and not yet removed.
    function test_TheChainAccusedAnswersDuringThePause() public {
        _threeOverturnsOnDistinctDisputes(arbiter);

        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "setup: the chain has accused"
        );
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "setup: they are still in the corps: accused, not removed"
        );

        bytes32 reply = keccak256("I ran all three disputes by the book, here are the logs");
        vm.prank(arbiter);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(
            reply, "there were overturns, and none of them is my fault"
        );

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(arbiter), reply,
            "the objection landed on chain before a verdict that may never come"
        );
    }

    /// ⚠️ A SECOND ACCUSATION BY THE CHAIN OPENS THE RIGHT AGAIN, and without the
    /// clearing in _recordArbiterMistake it would NOT have opened. This is a hole the
    /// original brief did not know: it listed the places where a proposal DISAPPEARS
    /// and closed with a clearing only the human door of its APPEARANCE
    /// (proposeRemoval). The chain lays its accusation past that door — by a direct
    /// write into storage.
    ///
    /// The scene has not one artificial step: the chain's accusation goes stale
    /// unexecuted (the button is nobody's, and nobody is obliged to press it), the
    /// person stays seated, the counter stays where it is — and the next overturn lays
    /// a new accusation. A reply to the previous one would have turned it into
    /// AlreadyAnswered forever.
    function test_ANewChainAccusationReopensTheRightToAnswer() public {
        _threeOverturnsOnDistinctDisputes(arbiter);

        vm.prank(arbiter);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(keccak256("a1"), "");

        // Nobody pressed: the accusation goes stale by itself. There is no withdrawal
        // and no vindication — nothing erases the reply along the way.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getProposalTTL());
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "setup: the previous accusation went stale unexecuted"
        );

        // A fourth overturn — the chain accuses again.
        _disputeAndOverturn(address(0x9E1), address(0x9E2));
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "setup: the chain has laid down a new accusation"
        );

        vm.prank(arbiter);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(keccak256("a2"), "");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(arbiter), keccak256("a2"),
            "they answered the chain's new accusation afresh rather than running into AlreadyAnswered"
        );
    }

    /// A vindication by the panel is the fourth place where an accusation disappears,
    /// and the original brief did not know it (it appeared later). The chain takes its
    /// word back entirely: there is no proposal, the counter is zero, the suspension
    /// is lifted — and there is no reply either, because there is nothing left to
    /// answer.
    function test_VindicationClosesTheAnswerToTheChainsAccusation() public {
        address v1 = address(0x7E1);
        address v2 = address(0x7E2);
        address v3 = address(0x7E3);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v1);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v2);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v3);

        _disputeAndOverturn(address(0x9F1), address(0x9F2));
        _disputeAndOverturn(address(0x9F3), address(0x9F4));
        address agr = _disputeAndOverturn(address(0x9F5), address(0x9F6));

        vm.prank(arbiter);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(keccak256("my side"), "");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(arbiter), keccak256("my side"),
            "setup: the reply to the chain's accusation landed"
        );

        usdc.mint(address(0x9F5), 100 * 10 ** 6);
        vm.prank(address(0x9F5));
        usdc.approve(address(diamond), 20 * 10 ** 6);
        vm.prank(address(0x9F5));
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.prank(v1);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(arbiter), bytes32(0),
            "the reply was taken away together with the accusation the panel withdrew"
        );
        vm.prank(arbiter);
        vm.expectRevert(ArbiterAccountabilityFacet.NothingToAnswer.selector);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(keccak256("again"), "");
    }

    /// The second consequence: the same call silenced THE AUTOMATIC PATH.
    ///
    /// The automatic road sets the same suspension from the same declaration
    /// (ArbiterRegistryStorage.SUSPENSION_WINDOW) and — on the removal itself — the
    /// same removedAt mark as a manual removal, and it does so WITH NO HUMAN
    /// throughout. A chief who lifted a suspension without a single check was
    /// switching off a mechanism deliberately built to work on its own; it cost zero
    /// gas beyond the call and left no "why" in the record.
    function test_ChiefCannotLiftAutoDemotionSuspension() public {
        address chief = address(0xC4);
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(chief);

        // Three REAL overturns on three different deals, and then the button.
        //
        // ⚠️ The removal moved two days forward, and the scene waits for it. The
        // property under test is the same and lies on the same half of the
        // discriminator — `removedAt != 0`. The other half, "the CHAIN's accusation
        // hangs and the removal has not happened yet", is guarded by a separate scene,
        // test_ChiefCannotLiftTheChainSuspensionWhileTheAccusationStands: without it
        // the chief would silence the fast lever in one transaction — exactly the way
        // round that was being closed.
        _threeOverturnsOnDistinctDisputes(arbiter);
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "setup: the automatic path removed the arbiter"
        );
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "setup: the automatic path set the same window as a manual removal"
        );

        vm.prank(chief);
        vm.expectRevert(ArbiterAccountabilityFacet.RemovalSuspensionIsRemovalAuthorityOnly.selector);
        ArbiterAccountabilityFacet(address(diamond)).liftSuspension(arbiter);

        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "the automatic path's window is beyond the chief"
        );
    }

    // ============================================================
    //  ONE DOOR WAS LOCKED AND THE NEXT ONE LED TO THE SAME PLACE.
    //
    //  liftSuspension refused the chief — while addArbiter, under the same
    //  onlyOwnerOrChief, called clearRemovalRecord(d, arbiter, true), which erases
    //  removedAt AND suspendedUntil at once. One call across the road gave precisely
    //  the result that had been forbidden, and on top of that returned a removed
    //  arbiter to the registry with their claims untouched.
    //
    //  The rule: undoing a removal is the mirror of a removal, and the chief may not
    //  remove.
    // ============================================================

    /// The direct side: returning A REMOVED arbiter is closed to the chief, and the
    /// way round did not happen — what is checked is not only the label of the error
    /// but that nothing happened behind it.
    function test_ChiefCannotReseatRemovedArbiter() public {
        address chief = address(0xC4);
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(chief);

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the chat log"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the chat log"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "setup: the removal set the window"
        );

        vm.prank(chief);
        vm.expectRevert(ArbiterRegistryFacet.ReseatingRemovedIsOwnerOnly.selector);
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);

        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "the window is in place: it was not lifted by a side door either"
        );
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "and the removed one did not come back into the corps"
        );
    }

    /// The reverse side, and without it the lock would be too wide: seating in general
    /// is still the chief's work. Somebody who left VOLUNTARILY is taken rather than a
    /// newcomer, because that is the case closest to the prohibition: the person is
    /// not in the corps, but there is no removal on them either — resignAsArbiter does
    /// not write `removedAt`. The check proves that the discriminator reads THE
    /// REMOVAL and not "absence from the registry".
    function test_ChiefStillSeatsSomeoneWhoResigned() public {
        address chief = address(0xC4);
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(chief);

        address who = address(0x5C);
        _addFreshArbiter(who);
        vm.prank(who);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(who));

        vm.prank(chief);
        ArbiterRegistryFacet(address(diamond)).addArbiter(who);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(who),
            "they left of their own accord, so the chief may bring them back: a removal has nothing to do with it"
        );
    }

    /// A LOCK ON THE SEAM. Returning to the corps MUST release the gate. The gate
    /// reads the ERASABLE removedAt; if somebody rehangs it on the eternal removal
    /// history (removalCount/lastRemovalAt), this test goes red — and without it
    /// nothing would: a review simulated that miss literally and got 0 red out of 831.
    /// A docstring explains WHY, but an explanation and a check are different things.
    ///
    /// It is THE OWNER who returns them, not the chief: after the fix above, returning
    /// a removed arbiter is an owner's action. The property does not change with the
    /// role, and the effect (addArbiter erases removedAt) is the same.
    function test_ChiefStillLiftsOrdinarySuspensionAfterReseat() public {
        address chief = address(0xC4);
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(chief);

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("x"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("x"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);   // erases removedAt

        ArbiterAccountabilityFacet(address(diamond)).suspendArbiter(arbiter);
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter));

        vm.prank(chief);
        ArbiterAccountabilityFacet(address(diamond)).liftSuspension(arbiter);

        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "brought back into the corps, and the chief lifts an ordinary suspension again"
        );
    }

    // ── The right to lift the window travels with the right to remove ──
    //
    // removeArbiterForCause deliberately pushes the owner out after a successor is
    // appointed: "there is no road back — otherwise collusion and a leaked chat log
    // would become entirely unremovable". But liftSuspension compared against the
    // owner ALWAYS, and the result was the opposite: the successor could not lift
    // their own window (the modifier did not see them), while the owner lifted
    // SOMEBODY ELSE'S — and after that a suspension cannot be restored by anything,
    // since suspendArbiter requires isArbiter.

    /// The shared setup of both checks: the DAO is switched on, a successor is named,
    /// and it is the successor who removes. There is no removal left for the owner in
    /// this scene.
    ///
    /// ⚠️ And no proposal from him either, since 17 August
    /// 2026: the accusation door moved with the right to act on it, so the
    /// successor lays his own record here — the owner's last action on this
    /// stand is naming him.
    function _handOverRemovalAndRemove(address dao) internal {
        _handOverRemovalRight(dao);

        _proposeAndWaitAs(dao, arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the chat log"));
        vm.prank(dao);
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the chat log"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "setup: the successor removed them and the window is set"
        );
    }

    // ── The pause reviewed (17 August 2026): the handover end to end ──

    /// THE WHOLE ROAD, WALKED BY THE SUCCESSOR ALONE. Not the pieces — the
    /// property. After the owner names him, every remaining action is the
    /// successor's: he proposes, he waits out the 48 hours, he removes. The
    /// former owner does nothing, and this test proves he does not have to.
    ///
    /// This is exactly what the pause broke and what that review repaired.
    /// Before the fix the successor could not lay a proposal at all
    /// (onlyOwnerOrChief admits neither the owner-that-was nor him), and since
    /// the pause made a proposal mandatory, the handover was cancelled by the
    /// own work: the right had moved, and using it still required a transaction
    /// from the man it had moved away from.
    ///
    /// Lives here, not on the light stand, because the property spans three
    /// facets and one storage: setDAOAddress and isRegisteredArbiter are the
    /// registry's, proposeRemoval and removeArbiterForCause the accountability
    /// facet's, and the DAO threshold is read out of the reputation namespace.
    function test_SuccessorRunsTheWholeRemovalAloneAfterHandover() public {
        address dao = address(0xDA0);

        // The owner's LAST act on this stand: earning governance is not his
        // doing at all (the threshold is reached by strangers), and naming the
        // successor IS the handover rather than a step of the removal.
        _handOverRemovalRight(dao);

        // And from here he is shut out — checked, not assumed. Without this the
        // test would still pass if the owner had kept the accusation door, and
        // "the successor can" would say nothing about "the owner need not".
        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), PROPOSAL_WORDS
        );

        // Everything below is the successor's own hand, and nothing else runs.
        vm.prank(dao);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), PROPOSAL_WORDS
        );
        vm.warp(
            vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay()
        );
        vm.prank(dao);
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            PROPOSAL_WORDS
        );

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "the successor walked the whole road themselves: proposed, waited, removed"
        );
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "and their own proposal was executed rather than left hanging"
        );
    }

    /// The direct side: whoever removed is entitled to open their own window. Before
    /// the fix they did not even pass the modifier — that is, after the handover
    /// NOBODY would open the window, and a door with no opener is worse than a door
    /// held by the owner.
    function test_DaoLiftsTheRemovalWindowAfterHandover() public {
        address dao = address(0xDA0);
        _handOverRemovalAndRemove(dao);

        vm.prank(dao);
        ArbiterAccountabilityFacet(address(diamond)).liftSuspension(arbiter);

        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "whoever holds the right to remove also holds the right to undo their own removal"
        );
    }

    /// The reverse side: the former holder of the door no longer enters it. Without
    /// this check, "the right travels with the right" would remain half done — the
    /// owner would go on opening SOMEBODY ELSE'S window, against the very argument
    /// written down in removeArbiterForCause.
    function test_OwnerCannotLiftTheRemovalWindowAfterHandover() public {
        address dao = address(0xDA0);
        _handOverRemovalAndRemove(dao);

        vm.expectRevert(ArbiterAccountabilityFacet.RemovalSuspensionIsRemovalAuthorityOnly.selector);
        ArbiterAccountabilityFacet(address(diamond)).liftSuspension(arbiter);

        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "the successor's window is beyond the owner: they handed removal over entirely"
        );
    }

    // ============================================================
    //  A REMOVAL WAS WEAKER THAN A SUSPENSION AND CLOSED THE DOOR THAT SAVED.
    //
    //  A chain of THREE pieces of work, and not one of them shows it alone — which is
    //  why these tests live here, on a real diamond, and not on the light bench:
    //
    //    removeArbiterForCause clears the status but touches neither disputeClaims
    //               nor openClaimCount nor suspendedUntil;
    //    the original
    //    code     — submitVerdict is gated on THE CLAIM (`disputeClaims[agreement]
    //               != caller`) and not on the status: a removed arbiter still submits
    //               verdicts on every dispute they claimed;
    //    suspension — suspendArbiter reverts NotAnArbiter on an already removed
    //               arbiter, so after a removal they can no longer BE suspended.
    //
    //  The result before the fix: the owner finds collusion, presses "remove for
    //  cause" — and thereby unlocks the last door for the bribed arbiter. They submit
    //  verdicts, a day later any passer-by finalises them, and the pots go to the side
    //  that paid the bribe. An inversion of the design: the weak measure held the
    //  money, the strong one did not.
    //
    //  The fix: a removal IMPLIES a suspension. `_requireNotSuspended` in
    //  finalizeVerdict reads THE VERDICT'S ARBITER (v.arbiter) and not the caller —
    //  checked against the code — so one line in removeArbiterForCause really does
    //  freeze a removed arbiter's verdicts for the same 72 hours in which the owner
    //  has time to go through overturnVerdict/freezeVerdict.
    // ============================================================

    /// The same cycle as _disputeAndOverturn, but stopping at a SUBMITTED verdict:
    /// that state — "the verdict is submitted, finalisation is waiting for
    /// FINALIZE_DELAY" — is the window a removal has to fit into.
    function _disputeAndSubmit(address cli, address exec) internal returns (address agreementAddr) {
        usdc.mint(cli, 1_000_000 * 10 ** 6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10 ** 6);
        vm.prank(address(diamond));
        agreementAddr = FactoryFacet(address(diamond)).deployAgreement(
            cli, exec, arbiter, AMOUNT, DEADLINE, TERMS, 0
        );
        vm.prank(cli);
        usdc.approve(agreementAddr, AMOUNT);
        vm.prank(cli);
        Agreement(agreementAddr).fund();
        vm.prank(exec);
        Agreement(agreementAddr).activate();
        vm.prank(cli);
        Agreement(agreementAddr).raiseDispute();

        _claimDisputeAs(agreementAddr, arbiter);

        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(agreementAddr, true);
    }

    /// The whole scenario. Cause.Collusion — collusion: exactly the cause the strong
    /// measure exists for, and it requires no mistake counter (the only variable in
    /// the test is the removal itself).
    function test_RemovedForCauseCannotFinalizeHisVerdictWithinTheWindow() public {
        address agreementAddr = _disputeAndSubmit(address(0x601), address(0x602));

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("chat log"));
        uint256 removedAtTs = vm.getBlockTimestamp();
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("chat log"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "setup: the removal happened"
        );

        uint256 until = removedAtTs + ArbiterAccountabilityFacet(address(diamond)).getSuspensionWindow();

        // FINALIZE_DELAY = 24 hours has passed, the suspension window (72 hours) has
        // not. Exactly the moment at which, before the fix, the pot went to the side
        // that paid the bribe.
        vm.warp(removedAtTs + 24 hours);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterRegistryFacet.ArbiterSuspendedError.selector, until)
        );
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);
    }

    /// The second half: a suspension from a removal expires by itself. A removed
    /// arbiter stays removed forever, but a verdict nobody overturned or froze within
    /// 72 hours executes in the ordinary way — otherwise one removal would freeze
    /// honest parties' money for ever, and that would be a new weapon.
    function test_RemovedForCauseCanFinalizeAfterTheWindow() public {
        address agreementAddr = _disputeAndSubmit(address(0x603), address(0x604));

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("chat log"));
        uint256 removedAtTs = vm.getBlockTimestamp();
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("chat log"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        vm.warp(
            removedAtTs + ArbiterAccountabilityFacet(address(diamond)).getSuspensionWindow()
        );
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agreementAddr).finalized,
            "after the window the verdict executes: the suspension is temporary here too"
        );
    }

    /// A control that the test above distinguishes the reasons for a refusal: the same
    /// dispute, the same moment — but WITHOUT a removal the finalisation goes through.
    /// Without this, "it reverts at 24 hours" could mean anything (FINALIZE_DELAY not
    /// passed, a broken mock) rather than "the suspension holds".
    function test_WithoutRemovalTheSameVerdictFinalizesAtTwentyFourHours() public {
        address agreementAddr = _disputeAndSubmit(address(0x605), address(0x606));

        vm.warp(vm.getBlockTimestamp() + 24 hours);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agreementAddr).finalized,
            "without a removal the same verdict on the same 24 hours executes"
        );
    }

    // ============================================================
    //  A SUSPENSION WAS ERASED BY NO EXIT DOOR AND NOT ON A RE-SEATING
    //
    //  Once a removal set a suspension, that became a direct contradiction of the
    //  branch's own rule: "the marks of a past removal do not outlive a re-seating".
    //  An owner repairing a mistaken removal with one addArbiter command would bring
    //  the person back with an unspent suspension — and they can silently neither
    //  claim, nor finalise, nor resign.
    // ============================================================

    /// Proved BY BEHAVIOUR rather than by reading a field: a returned arbiter must be
    /// able to resign, and resignAsArbiter is one of the three doors a suspension locks
    /// (_requireNotSuspended). Reading getSuspendedUntil would be weaker: a zero there
    /// could mean both "it was erased" and "it was never written".
    function test_ReseatingByOwnerClearsTheSuspensionLeftByRemoval() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "setup: the removal left a suspension behind"
        );

        // The owner has sorted it out and repairs a mistaken removal — a production road.
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "a re-seating must lift a suspension that has not run out"
        );

        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).resignAsArbiter();
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "the returned person works as an ordinary arbiter and not as a mute one"
        );
    }

    // ============================================================
    //  THE clearRemovalRecord CALL IN applyAsArbiter
    //
    //  It was covered by nothing — the mutation gave 0 red. Only the second entrance
    //  door, addArbiter, was covered. And that is precisely the half that WILL OUTLIVE
    //  the first: after the DAO is activated addArbiter is dead (SeatingHandedOver)
    //  and self-enrolment remains the ONLY entrance into the corps — so the door that
    //  will work longest was the one left without a lock.
    // ============================================================

    uint256 constant SLOT_XP           = 0;
    uint256 constant SLOT_CLEAN_STREAK = 9;
    uint256 constant ARBITER_BOND      = 50 * 10 ** 6;

    function _grantSelfRegistrationGate(address who) internal {
        vm.store(
            address(diamond),
            keccak256(abi.encode(who, uint256(REP_BASE) + SLOT_XP)),
            bytes32(uint256(10_000))
        );
        vm.store(
            address(diamond),
            keccak256(abi.encode(who, uint256(REP_BASE) + SLOT_CLEAN_STREAK)),
            bytes32(uint256(50))
        );
        usdc.mint(who, ARBITER_BOND);
        vm.prank(who);
        usdc.approve(address(diamond), ARBITER_BOND);
    }

    /// Governance is on — which means self-enrolment has become the only door into the
    /// corps: `addArbiter` and `setChiefArbiter` are closed while the DAO is live.
    ///
    /// ⚠️ "It arrives by itself, without a single human transaction" used to stand
    /// here — a decision of 26 August 2026 cancelled that: nothing arrives by itself,
    /// the threshold became a condition and a human presses.
    function test_SelfRegistrationClearsTheRemovalRecord() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        vm.prank(arbiter);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(keccak256("my side"), "");

        _handOverRemovalRight(address(0xDA0));
        assertTrue(ArbiterRegistryFacet(address(diamond)).isDaoActive(), "setup: governance was switched on by a human");

        _grantSelfRegistrationGate(arbiter);
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter), "setup: the self-enrolment went through");

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(arbiter),
            bytes32(0),
            "a reply to a PAST removal does not outlive a re-seating: otherwise a second accusation would stay unanswered forever"
        );

        // The second half of the same clearing: removedAt. It is read behaviourally —
        // a serving, not yet removed arbiter must not be able to "answer" a long-closed
        // accusation.
        vm.prank(arbiter);
        vm.expectRevert(ArbiterAccountabilityFacet.NothingToAnswer.selector);
        ArbiterAccountabilityFacet(address(diamond)).respondToRemoval(keccak256("phantom"), "");
    }

    // ============================================================
    //  THE SEAM WITH SELF-ENROLMENT — CLOSED BY A PARAMETER (the owner's decision,
    //  16 August)
    //
    //  The first version of the suspension fix erased suspendedUntil in the LIBRARY
    //  clearing shared by both entrance doors — and thereby opened a hole in exactly
    //  the removal-implies-suspension rule: somebody removed for cause paid a fresh
    //  50 USDC bond, came back by self-enrolment and finalised verdicts claimed BEFORE
    //  the removal, without waiting 72 hours.
    //
    //  Closed not by a second copy of the function but by an explicit liftSuspension
    //  parameter: addArbiter passes true and applyAsArbiter false. The argument in one
    //  sentence: the suspension is not imposed by the arbiter, so it is not for them
    //  to lift.
    //
    //  The two tests below guard DIFFERENT sides of the parameter, and both are
    //  needed: one catches a `true` where a `false` belongs, the other the reverse.
    // ============================================================

    /// The `false` side. Self-enrolment returns them to the corps but does NOT quench
    /// the suspension — and that is proved by behaviour rather than by reading a
    /// field: the returned person still cannot take their verdict away through
    /// finalisation.
    function test_SelfRegistrationDoesNotLiftSuspension() public {
        address agreementAddr = _disputeAndSubmit(address(0x607), address(0x608));

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"));
        uint256 removedAtTs = vm.getBlockTimestamp();
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter), "setup: the removal suspended them");

        _handOverRemovalRight(address(0xDA0));
        _grantSelfRegistrationGate(arbiter);
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "setup: the self-enrolment went through and they are back in the corps"
        );

        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "self-enrolment does NOT lift the suspension: it was not they who imposed it"
        );

        // The main consequence the parameter exists for: the window holds despite the
        // return. A thaw cannot be bought with a fresh bond.
        uint256 until = removedAtTs + ArbiterAccountabilityFacet(address(diamond)).getSuspensionWindow();
        vm.warp(removedAtTs + 24 hours);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterRegistryFacet.ArbiterSuspendedError.selector, until)
        );
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);
    }

    /// The `true` side. The same suspension is lifted by A SEATING BY THE OWNER — they
    /// are undoing their own decision, and returning a person mute would be exactly
    /// the hole this was introduced for. The same dispute and the same moment as in the
    /// test above: the only difference is which entrance door fired.
    function test_OwnerReseatingLiftsTheSuspensionSelfRegistrationKeeps() public {
        address agreementAddr = _disputeAndSubmit(address(0x609), address(0x60A));

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"));
        uint256 removedAtTs = vm.getBlockTimestamp();
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "the owner undoes their own decision, and the suspension goes with it"
        );

        vm.warp(removedAtTs + 24 hours);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreementAddr);
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).getPendingVerdict(agreementAddr).finalized,
            "the removal was undone by the owner, and the returned arbiter's verdict executes in the ordinary way"
        );
    }

    // ============================================================
    //  A CONTROL ON THE SEAM BETWEEN THE TWO COPIES OF _msgSender() — not a lock, and
    //  that matters.
    //
    //  The ArbiterAccountabilityFacet docstring promised that the body "must match
    //  byte for byte — checked by test_MsgSenderMatchesRegistry". The promise was
    //  false: there is no byte-for-byte comparison at all, and the named test drives
    //  only respondToRemoval through the forwarder, that is, it speaks about ONE copy.
    //  That test was itself renamed to
    //  test_RespondToRemovalThroughForwarderCreditsHuman — the name was brought into
    //  line with what it does.
    //
    //  Here there is ONE real MinimalForwarder, ONE diamond, ONE storage, ONE signer,
    //  and the answers of BOTH implementations are compared against each other.
    //
    //  ⚠️ AN HONEST MEASUREMENT, so that this test does not look stronger than it is:
    //  it is never the only red. Corrupting the original gives 6 red, five of them on
    //  the registry's own gasless path; corrupting the copy gives 2 red, one of them
    //  test_RespondToRemovalThroughForwarderCreditsHuman. Each copy is proved without
    //  it against an EXTERNAL truth — the signer's address. What it catches is
    //  something else: the PAIR drifting apart on shared storage (measured: the copy
    //  reads a foreign FactoryStorage field — 2 red, both about this pair).
    // ============================================================

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    function _signFwd(MinimalForwarder fwd, uint256 pk, MinimalForwarder.ForwardRequest memory req)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            FWD_TYPEHASH, req.from, req.to, req.value, req.gas, req.nonce, keccak256(req.data)
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            keccak256(abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MinimalForwarder")),
                keccak256(bytes("0.0.1")),
                block.chainid,
                address(fwd)
            )),
            structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _forward(MinimalForwarder fwd, uint256 pk, address from, bytes memory data) internal {
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  from,
            to:    address(diamond),
            value: 0,
            gas:   1_000_000,
            nonce: fwd.getNonce(from),
            data:  data
        });
        vm.prank(address(0x9999)); // the relayer: a third address, neither the arbiter nor the forwarder
        (bool ok, bytes memory ret) = fwd.execute(req, _signFwd(fwd, pk, req));
        assertTrue(ok, string.concat("forwarded call failed: ", vm.toString(ret)));
    }

    function test_MsgSenderAgreesAcrossBothFacetsOnOneForwarder() public {
        uint256 pk = 0xCA11;
        address human = vm.addr(pk);

        MinimalForwarder fwd = new MinimalForwarder();
        FactoryFacet(address(diamond)).setTrustedForwarder(address(fwd));
        ArbiterRegistryFacet(address(diamond)).addArbiter(human);

        // ── Implementation 1: ArbiterRegistryFacet._msgSender ──
        // setArbiterChatKey writes the keys BY SENDER, and they are read back
        // outwards by address. So a miss in attribution is visible directly and not
        // only through a revert: the keys would have gone to the forwarder, and
        // getArbiterChatKeys(human) would have returned zeroes.
        bytes32 boxKey  = keccak256("box");
        bytes32 signKey = keccak256("sign");
        _forward(
            fwd, pk, human,
            abi.encodeWithSelector(ArbiterRegistryFacet.setArbiterChatKey.selector, boxKey, signKey)
        );
        (bytes32 gotBox, bytes32 gotSign) =
            ArbiterAccountabilityFacet(address(diamond)).getArbiterChatKeys(human);

        // ── Implementation 2: ArbiterAccountabilityFacet._msgSender ──
        _proposeAndWait(human, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            human, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        bytes32 reply = keccak256("my side");
        _forward(
            fwd, pk, human,
            // ⚠️ There have been two arguments since 17 August 2026 (the words of the
            // reply). The selector is taken from the type — the change of signature is
            // picked up by the compiler and not by a person reading this file.
            abi.encodeWithSelector(ArbiterAccountabilityFacet.respondToRemoval.selector, reply, "")
        );
        bytes32 gotReply = ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(human);

        // ── Comparing the pair ──
        assertEq(gotBox,  boxKey,  "the ArbiterRegistryFacet implementation must record it for THE PERSON");
        assertEq(gotSign, signKey, "the ArbiterRegistryFacet implementation must record it for THE PERSON");
        assertEq(gotReply, reply,  "the ArbiterAccountabilityFacet implementation must record it for THE SAME person");

        // A control that neither of the two attributed the work to the forwarder.
        // Without this half, "both recorded it for the person" could still coexist
        // with one of the copies writing for BOTH.
        (bytes32 fwdBox, bytes32 fwdSign) =
            ArbiterAccountabilityFacet(address(diamond)).getArbiterChatKeys(address(fwd));
        assertEq(fwdBox,  bytes32(0), "the keys do not belong to the forwarder");
        assertEq(fwdSign, bytes32(0), "the keys do not belong to the forwarder");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getRemovalReply(address(fwd)),
            bytes32(0),
            "the reply does not belong to the forwarder"
        );
    }

    // ============================================================
    //  ONE VERDICT, AT MOST ONE JUDICIAL MISTAKE (18 August 2026)
    //
    //  overturnVerdict wrote v.overturned and never read it back as a
    //  refusal. Three calls against the SAME agreement, inside one block,
    //  reached MAX_ARBITER_MISTAKES — so the price of unseating an arbiter
    //  was one submitted verdict, not three disputes.
    //
    //  The gate closes that. Where it sits among the three older checks is a
    //  property of its own, and the two scenes below pin it: both states are
    //  reachable with `overturned` already true, and in both the older reason
    //  is the more final of the two and must survive.
    //
    //  ⚠️ THE GATE WAS ONLY HALF OF IT (found on review, same day). Hand first
    //  and panel second stayed open — deliberately, the appeal is the only
    //  check on that door — and booked the second mistake there instead, so
    //  unseating an arbiter still cost two disputes rather than three. That
    //  half is closed inside resolveAppeal; the scenes for it live in
    //  test/Diamond.t.sol, where the appeal machinery is.
    // ============================================================

    /// The price of unseating an arbiter must not equal one submitted verdict.
    ///
    /// `_disputeAndOverturn` is the file's own way in: it builds the dispute,
    /// submits the verdict AND performs the first overturn. No second way of
    /// building one is written here.
    function test_OneVerdictCannotBeOverturnedThreeTimes() public {
        address agreement = _disputeAndOverturn(address(0x661), address(0x662));

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1,
            "first overturn counts once"
        );

        vm.expectRevert(ArbiterRegistryFacet.AlreadyOverturned.selector);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agreement, false);

        vm.expectRevert(ArbiterRegistryFacet.AlreadyOverturned.selector);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agreement, true);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1,
            "one verdict, one mistake"
        );
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "still seated after one bad verdict"
        );
    }

    /// Placement, half one: overturned AND finalized is a reachable state —
    /// finalizeVerdict leaves `overturned` standing, it only adds `finalized`.
    /// The refusal a person reads there must stay AlreadyFinalized: the verdict
    /// is over, which is the larger fact. Lifting the new gate above the
    /// finalized check swaps the reason and says the smaller one instead.
    ///
    /// ⚠️ vm.getBlockTimestamp(), not block.timestamp: under via_ir solc treats
    /// TIMESTAMP as constant within a call.
    function test_OverturnedThenFinalizedStillRefusesAsFinalized() public {
        address agreement = _disputeAndOverturn(address(0x663), address(0x664));

        vm.warp(vm.getBlockTimestamp() + 24 hours + 1); // FINALIZE_DELAY
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agreement);

        vm.expectRevert(ArbiterRegistryFacet.AlreadyFinalized.selector);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agreement, true);
    }

    // ============================================================
    //  THE AUTOMATIC-REMOVAL RECORD NAMES ITS ORIGIN
    //
    //  With three overturned verdicts the owner removes an arbiter, bypassing the door
    //  with a cause. The earlier single-field event read as the automatic path — that
    //  is, it laid the blame on the removed arbiter. The automatic path has exactly
    //  three roads, and each must be named as its own.
    //
    //  ⚠️ Three verdicts and not three presses on one: since 18 August 2026 an
    //  overturned verdict refuses with AlreadyOverturned. Both scenes below build
    //  THREE DIFFERENT disputes — the property of the scene did not change, only the
    //  price did.
    // ============================================================

    /// Road one: the owner overturns a verdict.
    ///
    /// ⚠️ THE SCENE WAS REBUILT, and the property under test was inverted with it.
    /// A third overturn used to REMOVE an arbiter, and `ArbiterDemoted` was bound to
    /// NAME whoever pressed — the test guarded that the record would not lay the blame
    /// on the owner when somebody else pressed. A third overturn no longer removes: it
    /// suspends and opens an accusation IN THE CHAIN'S NAME, and it has no accuser at
    /// all — the `by` field in the record is zero, and the event has no such field by
    /// construction.
    ///
    /// The property became stronger rather than weaker: the old one rested on the
    /// right address being put into the event (a substitution gave 0 red out of 840
    /// until the DAO scene below was written), the present one on there being nowhere
    /// to put it.
    ///
    /// ⚠️ Three DIFFERENT disputes: an overturned verdict refuses AlreadyOverturned.
    function test_TheChainsAccusationNamesNobodyOnTheOverturnPath() public {
        _disputeAndOverturn(address(0x651), address(0x652));
        _disputeAndOverturn(address(0x653), address(0x654));

        address agr = _disputeAndSubmit(address(0x655), address(0x656));

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ArbiterRegistryFacet.RemovalProposedByChain(
            arbiter,
            uint8(ArbiterRegistryFacet.DemotionPath.OwnerOverturn),
            agr,
            vm.getBlockTimestamp()
        );
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "a third overturn no longer removes: it accuses"
        );
        (, , , address by, bool live) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertTrue(live, "the accusation is alive");
        assertEq(by, address(0), "and nobody's: a human pressed, and the chain accuses");
    }

    /// The same road one, but IT IS NOT THE OWNER WHO PRESSES. Without this scene the
    /// central property was guarded by nothing: across the whole suite owner ==
    /// address(this), overturnVerdict was nowhere called under vm.prank, and
    /// substituting `by` with OwnershipLib.contractOwner() gave ZERO red out of 840 —
    /// the tests proved "the record names the owner" rather than "the record names
    /// whoever pressed".
    ///
    /// The scene is a production one and not invented: onlyOwnerOrDAO admits the
    /// governance address too, and setDAOAddress PLUS a confirmation by that address
    /// itself is what seats it there (since 26 August 2026 a proposal alone is not
    /// enough, and the scene proves that along the way: without the acceptDAOAddress
    /// line below the press gets NotOwnerOrDAO).
    ///
    /// ⚠️ THERE IS DELIBERATELY NO `activateDAO()` HERE, and that is not forgetfulness.
    /// The shared right begins with the APPOINTMENT of the address and not with the
    /// activation of governance — the `onlyOwnerOrDAO` modifier does not ask about
    /// activation at all. With an activation line the scene would stop checking that:
    /// the measurement "gate the modifier's DAO branch on isDaoActive()" gave 0 red
    /// out of 855, because in the single scene with a DAO governance was active as
    /// well. Without the line the property is nailed by a test (the same measurement
    /// gives 1 red, this test, with the cause confirmed by the trace:
    /// `NotOwnerOrDAO()`), and any future attempt to gate the branch will require a
    /// DELIBERATE decision rather than passing in silence.
    ///
    /// Whether it should be gated is not decided by the test — it only stops the
    /// behaviour being changed unnoticed. The analysis of the ratchet itself (the owner
    /// reappoints the address freely before isDaoActive() and no longer after) is
    /// recorded separately.
    function test_TheChainsAccusationNamesNobodyEvenWhenTheDaoPressed() public {
        address dao = address(0x6D40);
        ArbiterRegistryFacet(address(diamond)).setDAOAddress(dao);
        vm.prank(dao);
        ArbiterRegistryFacet(address(diamond)).acceptDAOAddress();
        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isDaoActive(),
            "setup: governance is APPOINTED and CONFIRMED but not activated, so the rights already exist"
        );
        assertTrue(dao != owner, "setup: the one pressing and the owner are DIFFERENT addresses");

        // The owner presses the first two mistakes and governance the third.
        //
        // ⚠️ The scene was rebuilt together with its neighbour: what used to be guarded
        // here was "the record names WHOEVER PRESSED and not the owner by default"
        // (measured: 0 red out of 840 without this scene). Now the record names NOBODY,
        // and this scene guards that "nobody" means exactly nobody — and not "whoever's
        // address happened to be to hand". The presser is an address DIFFERENT from the
        // owner; were anybody's name to appear in the accusation, it would be visible
        // here.
        //
        // ⚠️ Three DIFFERENT disputes, see the scene above.
        _disputeAndOverturn(address(0x65B), address(0x65C));
        _disputeAndOverturn(address(0x65D), address(0x65E));

        address agr = _disputeAndSubmit(address(0x65F), address(0x660));

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ArbiterRegistryFacet.RemovalProposedByChain(
            arbiter,
            uint8(ArbiterRegistryFacet.DemotionPath.OwnerOverturn),
            agr,
            vm.getBlockTimestamp()
        );
        vm.prank(dao);
        ArbiterRegistryFacet(address(diamond)).overturnVerdict(agr, false);

        (, , , address by, ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertEq(by, address(0), "governance pressed, and the accusations are nobody's");
        assertTrue(by != dao, "and certainly not their name");
    }

    /// A zero enum value is neither a road nor an accusation. A forgotten or new road
    /// gets a zero by default in Solidity; what is checked is that Unspecified and not
    /// OwnerOverturn stands at zero — otherwise forgetfulness would silently accuse the
    /// owner. The check compares NUMBERS and not names: names would agree with
    /// themselves in any order.
    function test_ZeroDemotionPathIsNotAnAccusation() public pure {
        assertEq(
            uint8(ArbiterRegistryFacet.DemotionPath.Unspecified), 0,
            "a zero value must mean 'the path is not named'"
        );
        assertTrue(
            uint8(ArbiterRegistryFacet.DemotionPath.OwnerOverturn) != 0,
            "not one real path may sit at zero, or the default would be an accusation"
        );
        assertTrue(uint8(ArbiterRegistryFacet.DemotionPath.AgreementTimeout) != 0, "the same for a timeout");
        assertTrue(uint8(ArbiterRegistryFacet.DemotionPath.AppealVote) != 0, "the same for the votes");
    }

    /// Road two: the dispute was never finished and the agreement reports a timeout
    /// itself. There is no presser at all — msg.sender here is THE AGREEMENT ITSELF,
    /// and recording it as "who pressed" would be a lie. So `by` is zero and the deal
    /// is named in a separate field.
    function test_TheChainsAccusationNamesNobodyOnTheTimeoutPath() public {
        _disputeAndOverturn(address(0x653), address(0x654));
        _disputeAndOverturn(address(0x655), address(0x656));

        // A third deal: the dispute is claimed and NOT carried through to a verdict.
        address cli = address(0x657);
        address exec = address(0x658);
        usdc.mint(cli, 1_000_000 * 10 ** 6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10 ** 6);
        vm.prank(address(diamond));
        address agr = FactoryFacet(address(diamond)).deployAgreement(
            cli, exec, arbiter, AMOUNT, DEADLINE, TERMS, 0
        );
        vm.prank(cli);
        usdc.approve(agr, AMOUNT);
        vm.prank(cli);
        Agreement(agr).fund();
        vm.prank(exec);
        Agreement(agr).activate();
        vm.prank(cli);
        Agreement(agr).raiseDispute();
        _claimDisputeAs(agr, arbiter);

        // DISPUTE_WINDOW = 4 days (declared in src/Agreement.sol); strictly GREATER.
        vm.warp(vm.getBlockTimestamp() + 4 days + 1);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ArbiterRegistryFacet.RemovalProposedByChain(
            arbiter,
            uint8(ArbiterRegistryFacet.DemotionPath.AgreementTimeout),
            agr,
            vm.getBlockTimestamp()
        );
        vm.prank(cli);
        Agreement(agr).triggerArbiterTimeout();

        // ⚠️ AND THE MAIN THING HERE IS THAT IT HAPPENED AT ALL. Agreement executes
        // this road inside an EMPTY try/catch: a revert would be swallowed silently,
        // and "not punished at all" would look from outside exactly like "punished". A
        // later change added the writing of a proposal to this branch — revert-free by
        // construction, and here is the proof that it arrived.
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "a third mistake by timeout no longer removes: it accuses"
        );
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter));
    }

    /// Road three: an appeal. There is no presser here either — resolveAppeal may be
    /// called by anybody, and recording them as the culprit would be the worst of the
    /// three possible untruths: it is THE VOTES that decide, not whoever pressed "sum
    /// it up". `by` is zero, and the voters are read from AppealVoteCast on the same
    /// agreement.
    function test_TheChainsAccusationNamesNobodyOnTheAppealPath() public {
        _disputeAndOverturn(address(0x659), address(0x65A));
        _disputeAndOverturn(address(0x65B), address(0x65C));

        address v1 = address(0x6A1);
        address v2 = address(0x6A2);
        address v3 = address(0x6A3);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v1);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v2);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v3);

        address cli = address(0x65D);
        address exec = address(0x65E);
        address agr = _disputeAndSubmit(cli, exec);
        // submitVerdict(agr, true) — the client won, so it is the executor who appeals.
        // APPEAL_DEPOSIT is 20 USDC.
        usdc.mint(exec, 100 * 10 ** 6);
        vm.prank(exec);
        usdc.approve(address(diamond), 20 * 10 ** 6);
        vm.prank(exec);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.prank(v1);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);   // overturn
        vm.prank(v2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);   // overturn
        vm.prank(v3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);  // leave it

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ArbiterRegistryFacet.RemovalProposedByChain(
            arbiter,
            uint8(ArbiterRegistryFacet.DemotionPath.AppealVote),
            agr,
            vm.getBlockTimestamp()
        );
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "the votes overturned the verdict: a third mistake in a row, and it accuses rather than removes"
        );
        (, , , address by, bool live) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertTrue(live);
        assertEq(by, address(0), "it was THE VOTES that decided: calling whoever pressed 'the one who summed up' would be the worst untruth");
    }

    // ============================================================
    //  THE ETERNAL RECORD OF REMOVALS
    //
    //  removedAt and removalReply are erased by any re-seating, and that is right:
    //  they answer the question "did they answer THE CURRENT accusation". But then the
    //  card shows a clean person to somebody who was removed three times — and the
    //  erasing door belongs to the accuser (addArbiter) and, once the DAO is switched
    //  on, to the accused themselves (applyAsArbiter).
    // ============================================================

    /// A removal for cause → a seating back → a removal for a DIFFERENT cause.
    /// The erasable half is zeroed, the eternal one grows.
    function test_StandingRemembersRemovalsAcrossReseating() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        (, , , , , , , , , uint256 removedAt1, , uint256 count1, uint256 lastAt1, uint8 cause1)
            = ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(arbiter);
        assertGt(removedAt1, 0, "the current removal is marked");
        assertEq(count1, 1, "one removal");
        assertEq(lastAt1, vm.getBlockTimestamp(), "the moment of the last removal is recorded");
        assertEq(cause1, uint8(ArbiterAccountabilityFacet.Cause.Collusion) + 1,
            "the cause is recorded with an offset: zero must mean 'never removed'");

        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);

        (, , , , , , , , , uint256 removedAt2, , uint256 count2, uint256 lastAt2, uint8 cause2)
            = ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(arbiter);
        assertEq(removedAt2, 0, "there is no current removal: it was undone by a seating");
        assertEq(count2, 1, "but a seating does not erase a past removal");
        assertEq(lastAt2, lastAt1, "the moment of the past removal remains");
        assertEq(cause2, cause1, "the cause of the past removal remains");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("leak"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Leak, keccak256("leak"), address(0),
            "published the chat log of a dispute to a third party"
        );

        (, , , , , , , , , , , uint256 count3, uint256 lastAt3, uint8 cause3)
            = ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(arbiter);
        assertEq(count3, 2, "a second removal: the counter is two");
        assertEq(lastAt3, vm.getBlockTimestamp(), "the moment was updated to the last one");
        assertEq(cause3, uint8(ArbiterAccountabilityFacet.Cause.Leak) + 1, "the cause was updated");
    }

    /// An automatic demotion is a removal too, and it is remembered too. It has no
    /// cause: the chain removed the arbiter over a streak of mistakes and not over
    /// anybody's accusation, and the code says so outright rather than pretending to be
    /// cause number zero.
    ///
    /// But "there is no cause" does not yet mean "there is nothing to say". Road one:
    /// an overturn by the owner. The code must differ from the codes of the other two
    /// roads — otherwise the distinction, for which a separate event field was spent,
    /// is lost in the ONLY place that gets read (nobody reads the logs).
    function test_AutoDemotionByOverturnRecordsItsOwnPath() public {
        _disputeAndOverturn(address(0x721), address(0x722));
        _disputeAndOverturn(address(0x723), address(0x724));
        _disputeAndOverturn(address(0x725), address(0x726));

        // ⚠️ A third mistake accuses, and the common door removes two days later. The
        // card must name the road all the same — that is what chainProposalPath exists
        // for: the road is known at the moment of the mistake and recorded at the
        // moment of the removal.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));

        (, , , , , , , , , , , uint256 count, uint256 lastAt, uint8 cause)
            = ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(arbiter);
        assertEq(count, 1, "the automatic path removed them, and the counter grew just as it does by hand");
        assertEq(lastAt, vm.getBlockTimestamp(), "the moment of the automatic removal is recorded: the moment of THE REMOVAL, not of the mistake");
        assertEq(cause, AUTO_OVERTURN,
            "the card names the path: it was AN OVERTURN that removed them, not a timeout and not the votes");
        assertTrue(cause != AUTO_TIMEOUT,
            "and it must differ from a timeout");
        assertTrue(cause != AUTO_APPEAL,
            "and from the votes on an appeal");
    }

    /// Road two on the card: the agreement reported a timeout. The scene is the same as
    /// in test_ArbiterDemotedNamesNobodyOnTheTimeoutPath, but a DIFFERENT place is
    /// checked — not the feed but the card. They had to be separated because it is the
    /// card that gets read.
    function test_AutoDemotionByTimeoutRecordsItsOwnPath() public {
        _disputeAndOverturn(address(0x727), address(0x728));
        _disputeAndOverturn(address(0x729), address(0x72A));

        address cli = address(0x72B);
        address exec = address(0x72C);
        usdc.mint(cli, 1_000_000 * 10 ** 6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10 ** 6);
        vm.prank(address(diamond));
        address agr = FactoryFacet(address(diamond)).deployAgreement(
            cli, exec, arbiter, AMOUNT, DEADLINE, TERMS, 0
        );
        vm.prank(cli);
        usdc.approve(agr, AMOUNT);
        vm.prank(cli);
        Agreement(agr).fund();
        vm.prank(exec);
        Agreement(agr).activate();
        vm.prank(cli);
        Agreement(agr).raiseDispute();
        _claimDisputeAs(agr, arbiter);

        // DISPUTE_WINDOW = 4 days; strictly GREATER.
        vm.warp(vm.getBlockTimestamp() + 4 days + 1);
        vm.prank(cli);
        Agreement(agr).triggerArbiterTimeout();

        // ⚠️ A third mistake accuses, and the common door removes two days later. The
        // card must name the road all the same — that is what chainProposalPath exists
        // for: the road is known at the moment of the mistake and recorded at the
        // moment of the removal.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));

        (, , , , , , , , , , , uint256 count, , uint8 cause)
            = ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(arbiter);
        assertEq(count, 1, "a timeout removed them: the counter grew");
        assertEq(cause, AUTO_TIMEOUT,
            "the card names the path: it was A TIMEOUT that removed them");
        assertTrue(cause != AUTO_OVERTURN,
            "and it must differ from an overturn by the owner");
    }

    /// Road three on the card: THE VOTES overturned it on appeal. The most loaded with
    /// meaning of the three: "removed automatically" and "removed by a panel's
    /// decision" are different things to whoever reads an arbiter's card.
    function test_AutoDemotionByAppealRecordsItsOwnPath() public {
        _disputeAndOverturn(address(0x72D), address(0x72E));
        _disputeAndOverturn(address(0x72F), address(0x730));

        address v1 = address(0x7A1);
        address v2 = address(0x7A2);
        address v3 = address(0x7A3);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v1);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v2);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v3);

        address cli = address(0x731);
        address exec = address(0x732);
        address agr = _disputeAndSubmit(cli, exec);
        usdc.mint(exec, 100 * 10 ** 6);
        vm.prank(exec);
        usdc.approve(address(diamond), 20 * 10 ** 6);
        vm.prank(exec);
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);

        vm.prank(v1);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);

        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        // ⚠️ A third mistake accuses, and the common door removes two days later. The
        // card must name the road all the same — that is what chainProposalPath exists
        // for: the road is known at the moment of the mistake and recorded at the
        // moment of the removal.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));

        (, , , , , , , , , , , uint256 count, , uint8 cause)
            = ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(arbiter);
        assertEq(count, 1, "the votes removed them: the counter grew");
        assertEq(cause, AUTO_APPEAL,
            "the card names the path: it was THE VOTES that removed them");
        assertTrue(cause != AUTO_OVERTURN,
            "and it must differ from an overturn by the owner");
    }

    /// The sharpest half: once the DAO is switched on, the erasing door falls to THE
    /// ACCUSED themselves. applyAsArbiter calls the same clearRemovalRecord — and it
    /// must not carry the history away with it.
    function test_SelfRegistrationCannotEraseTheRemovalHistory() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        _handOverRemovalRight(address(0xDA0));
        _grantSelfRegistrationGate(arbiter);
        vm.prank(arbiter);
        ArbiterRegistryFacet(address(diamond)).applyAsArbiter();
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "setup: the self-enrolment went through"
        );

        (, , , , , , , , , uint256 removedAt, , uint256 count, , uint8 cause)
            = ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(arbiter);
        assertEq(removedAt, 0, "self-enrolment clears the current removal: that is its right");
        assertEq(count, 1, "but the accused cannot zero the history");
        assertEq(cause, uint8(ArbiterAccountabilityFacet.Cause.Collusion) + 1,
            "and the cause of the past removal stays readable");
    }

    // ============================================================
    //  THE FACT THE PUBLIC TEXT RESTS ON
    // ============================================================

    /// The fact docs/DECENTRALIZATION.md asserts: a removal forfeits WHATEVER bond
    /// there is — and a hand-seated arbiter has none at all.
    ///
    /// A non-zero `arbiterBond` is written by exactly one line in the whole of `src/`
    /// — `ArbiterRegistryFacet.applyAsArbiter` — and its very first line reverts
    /// `DAONotActive` while the DAO is off (the owner's decision of 1 August 2026:
    /// the arbiters at the start are hand-picked and their own). So for anybody who
    /// can physically be removed today, `bondForfeited` is provably zero — and the
    /// public document must say precisely that rather than threaten with fifty dollars
    /// that do not exist.
    ///
    /// ⚠️ This test does NOT guard the TEXT of the document. Guarding text would be
    /// guarding something other than the work — the very class of "a lock hunting for
    /// a name rather than a use" that gave 0 red out of 497 and 0 out of 568 in this
    /// project. It guards THE FACT the text rests on: corrupt the fact and this goes
    /// red. The reverse corruption (somebody putting an untruth back into the document)
    /// is caught by nothing, and that is recorded honestly rather than papered over
    /// with the appearance of a check.
    function test_HandSeatedArbiterHasNoBondToBurn() public {
        address seat = address(0x6401);
        ArbiterRegistryFacet(address(diamond)).addArbiter(seat);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(seat), 0,
            "a hand seating takes no bond, and the README tells the truth"
        );

        uint256 vaultBefore = ArbiterRegistryFacet(address(diamond)).getVaultBalance();

        // The sixth field of the event is bondForfeited. A zero here is what a reader
        // of the chain will see on any removal today.
        _proposeAndWait(seat, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("chat log"));
        vm.expectEmit(true, true, true, true, address(diamond));
        emit ArbiterAccountabilityFacet.ArbiterRemovedForCause(
            seat, owner, ArbiterAccountabilityFacet.Cause.Collusion, false, keccak256("chat log"), 0
        );
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            seat, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("chat log"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore,
            "there is nothing to burn: the arbiter vault did not grow by a cent"
        );
    }

    // ============================================================
    //  THE QUIET DOOR LEADS INTO THE COMMON ONE
    //
    //  A third judging mistake used to remove an arbiter on the spot: no proposal, no
    //  pause, no words, no agreement of the cause. Later work made the honest door
    //  expensive (48 hours and an explanation) while this one stayed free — and, what
    //  settled the matter, it OUTLIVED THE HANDOVER OF THE RIGHT: overturnVerdict
    //  stands under onlyOwnerOrDAO, and that admits the owner always.
    //
    //  It became: a third mistake suspends and opens a proposal IN THE CHAIN'S NAME.
    //  The removal goes through the common door, and after 48 hours anybody may press.
    // ============================================================

    /// The core: the seat survives the automatic road, while the person is stopped
    /// immediately and finds themselves accused.
    function test_ThirdMistakeSuspendsAndAccuses_ButDoesNotUnseat() public {
        address judged = arbiter;
        _giveBond(judged, ARBITER_BOND);
        _threeOverturnsOnDistinctDisputes(judged);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(judged),
            "the seat survives the automatic road"
        );
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(judged),
            "but they are stopped right now: the suspension is the fast road"
        );
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(judged),
            "and the chain has accused them"
        );

        (uint8 cause, bytes32 digest, uint256 proposedAt, address by, ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(judged);
        assertEq(by, address(0), "the accuser is the chain, and no name is given");
        assertEq(digest, bytes32(0), "there is no digest: the evidence is the chain's own state");
        assertEq(proposedAt, vm.getBlockTimestamp(), "the clock started from this second");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(judged), ARBITER_BOND,
            "the bond has not burned yet: an accusation is not a removal"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(judged), 3,
            "the counter HOLDS: the streak did not end because the chain noticed it"
        );

        // ⚠️ The expectation is taken from ANOTHER file — the
        // ArbiterAccountabilityFacet.Cause enum — while the actual value is read from
        // the chain. That is the guard on the CAUSE_*_MIRROR mirror in the registry:
        // permute the enum and the comparison diverges (an expectation must not be
        // derived from the thing under test).
        assertEq(
            cause, uint8(ArbiterAccountabilityFacet.Cause.OverturnedVerdicts),
            "the overturn road must be recorded as the cause OverturnedVerdicts"
        );
    }

    /// After 48 hours anybody may press. They get no right to DECIDE — everything was
    /// decided before them; what they get is the right to press.
    function test_AnyoneMayPressAfterThePause() public {
        address judged = arbiter;
        _giveBond(judged, ARBITER_BOND);
        _threeOverturnsOnDistinctDisputes(judged);
        uint256 vaultBefore = ArbiterRegistryFacet(address(diamond)).getVaultBalance();

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());

        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(judged);

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(judged),
            "there is no seat"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterBond(judged), 0,
            "the bond burns ON THE REMOVAL and not on the accusation"
        );
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance(), vaultBefore + ARBITER_BOND,
            "and it goes into the arbiter vault, as at the manual door"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(judged), 0,
            "the counter is zeroed ON THE REMOVAL: the evidence is spent by the removal built on it"
        );
        // The moment of the removal is marked — otherwise there would be nothing to
        // answer. It is read from the card: the facet has no separate removedAt getter.
        (, , , , , , , , , uint256 removedAt, , , , ) =
            ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(judged);
        assertGt(removedAt, 0, "the moment of the removal is marked");
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(judged),
            "the proposal is spent"
        );
    }

    /// ⚠️ WHAT THE THRESHOLD BRANCH DOES TO THE COUNTER — AND WHY THAT MATTERS NOW
    /// THAT A REMOVAL SETS A SUSPENSION.
    ///
    /// The name and the body of this scene were rewritten in review. It used to be
    /// called "the chain's accusation is still provable when the button is pressed"
    /// and it pressed the button — but the button no longer re-checks the cause at all
    /// and fires at a counter of 0, so the name promised an untruth and the press
    /// proved nothing about the counter. The review's measurement showed it in numbers:
    /// zeroing the counter at the threshold gives five reds, and NOT ONE of them about
    /// the press.
    ///
    /// What is guarded now is the real consequence of keeping the counter: a streak of
    /// judging mistakes did not end because the chain noticed it, and THE MANUAL door
    /// must be able to make use of it. The scene walks that road in full: nobody
    /// pressed the chain's accusation, it went stale over
    function test_TheThresholdKeepsTheStreakForTheManualDoor() public {
        _threeOverturnsOnDistinctDisputes(arbiter);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 3,
            "the streak did not end because the chain noticed it"
        );

        // Nobody pressed the button, and the chain's accusation went stale by itself.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getProposalTTL());
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "setup: the door is free again"
        );
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));

        // And the evidence still serves: the holder of the right proves the cause with it.
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "the counter that outlived the accusation proved the cause to a human"
        );
    }

    function test_TheButtonRefusesBeforeThePause() public {
        _threeOverturnsOnDistinctDisputes(arbiter);
        (, , uint256 proposedAt, , ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);

        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterAccountabilityFacet.RemovalTooEarly.selector,
                proposedAt + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay()
            )
        );
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "and nothing happened behind the refusal"
        );
    }

    /// The upper boundary of the window is the same as on the common door: a stale
    /// proposal is executed by nobody, the button included.
    function test_TheButtonRefusesAfterTheProposalGoesStale() public {
        _threeOverturnsOnDistinctDisputes(arbiter);
        (, , uint256 proposedAt, , ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);

        vm.warp(proposedAt + ArbiterAccountabilityFacet(address(diamond)).getProposalTTL());
        vm.prank(STRANGER);
        vm.expectRevert(
            abi.encodeWithSelector(ArbiterAccountabilityFacet.ProposalStale.selector, proposedAt)
        );
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);
    }

    /// There is nothing to override it with: an outsider does not execute A HUMAN
    /// accusation.
    function test_StrangerCannotPressAHumanAccusation() public {
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST,
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());

        vm.prank(STRANGER);
        vm.expectRevert(ArbiterAccountabilityFacet.NotAChainProposal.selector);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "a human accusation is executed by the holder of the right, and only by them"
        );
    }

    /// ⚠️ THE ORDER OF THE FIRST TWO REFUSALS IS LOAD-BEARING, not presentation. The
    /// proposal is FRESH and human: were the "whose door" check BELOW the clock, an
    /// outsider would get RemovalTooEarly(moment) — that is, would learn that an
    /// accusation hangs against the arbiter and when it matures. That is exactly the
    /// leak guarded on proposeRemoval
    /// (test_StrangerLearnsNothingAboutALiveProposal); swap the two lines in
    /// executeChainRemoval and this goes red.
    function test_TheButtonRefusesTheWrongDoorBeforeItMentionsTheClock() public {
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST,
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        // The clock is still running: the end of the pause is far off.
        vm.prank(STRANGER);
        vm.expectRevert(ArbiterAccountabilityFacet.NotAChainProposal.selector);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);
    }

    /// An empty record answers "there is no accusation" and not "the wrong door": an
    /// outsider must not be able to tell "there is nothing against them" from "what is
    /// against them is human" by the label of an error.
    function test_TheButtonSaysNothingStandsWhenNothingStands() public {
        vm.prank(STRANGER);
        vm.expectRevert(ArbiterAccountabilityFacet.NoLiveProposal.selector);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);
    }

    /// ⚠️ THE CHAIN YIELDS SILENTLY. `_recordArbiterMistake` arrives from
    /// notifyArbiterTimeout, and Agreement executes that inside an EMPTY try/catch: a
    /// revert would be swallowed silently and the arbiter would go unpunished without a
    /// trace. So somebody else's clock is not reset, somebody else's accuser is not
    /// overwritten, and nothing reverts.
    function test_ChainYieldsToALiveHumanProposalWithoutReverting() public {
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST,
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        (uint8 cause0, bytes32 digest0, uint256 before, address by0, ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _threeOverturnsOnDistinctDisputes(arbiter); // must not revert

        (uint8 cause1, bytes32 digest1, uint256 afterTs, address by1, ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertEq(afterTs, before, "the human clock is untouched");
        assertEq(by1, by0, "the human accuser is untouched");
        assertEq(cause1, cause0, "and the cause is theirs too");
        assertEq(digest1, digest0, "and the digest is theirs too");
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "and the suspension landed all the same: the fast lever is unconditional"
        );
        assertGe(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 3,
            "the evidence is kept for the next attempt: the counter is not zeroed"
        );
    }

    /// Withdrawing the chain's proposal returns the person to service IN FULL:
    /// otherwise a vindicated arbiter stays forever one overturn away from a new
    /// accusation.
    function test_WithdrawingTheChainAccusationClearsTheStreak() public {
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        _threeOverturnsOnDistinctDisputes(arbiter);

        vm.prank(CHIEF);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "one overturn must not accuse again"
        );
        assertFalse(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter));
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "they never stopped being an arbiter"
        );
    }

    /// The reverse side: withdrawing A HUMAN accusation does NOT touch the counter —
    /// otherwise the pair "propose and withdraw" would launder a real streak of
    /// mistakes.
    function test_WithdrawingAHumanProposalLeavesTheStreakAlone() public {
        _disputeAndOverturn(address(0x9B1), address(0x9B2));
        _disputeAndOverturn(address(0x9B3), address(0x9B4));
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 2);

        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST,
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 2,
            "the arbiter's mistakes did not go away because the accuser changed their mind"
        );
    }

    /// The chief withdraws the chain's accusation — named out loud and accepted: they
    /// get the chance to shield one of their own, but only with their name on chain.
    /// The key point is that `by == address(0)` does not refuse them with NotYourProposal.
    function test_ChiefMayWithdrawTheChainAccusationHeDidNotLay() public {
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        _threeOverturnsOnDistinctDisputes(arbiter);

        vm.expectEmit(true, true, false, false, address(diamond));
        emit ArbiterAccountabilityFacet.RemovalProposalWithdrawn(arbiter, CHIEF);
        vm.prank(CHIEF);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);
    }

    /// And an outsider does not withdraw. A zero in `by` does not mean "withdraw who
    /// you like": the branch requires the owner or the chief.
    function test_StrangerCannotWithdrawTheChainAccusation() public {
        _threeOverturnsOnDistinctDisputes(arbiter);

        vm.prank(STRANGER);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);

        assertTrue(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter));
    }

    /// ⚠️ THE RATCHET: AFTER THE HANDOVER THE QUIET DOOR IS CLOSED TOO.
    /// This is the argument that settled the matter: overturnVerdict stands under
    /// onlyOwnerOrDAO, and that admits the owner ALWAYS — so before this change a
    /// former owner removed the same arbiter with three overturns, and the handover
    /// ratchet the whole branch was built for was bypassed in one transaction.
    function test_QuietDoorDoesNotSurviveHandover() public {
        _handOverRemovalRight(address(0xDA0));
        _threeOverturnsOnDistinctDisputes(arbiter);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "without the door there is no removal"
        );
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "the chain's accusation landed: it is nobody's and knows nothing of a handover"
        );
    }

    /// ...and it is executed — by the same outsider, after the pause. The door is not
    /// locked by the handover: the chain presented the case itself, and there is nobody
    /// and nothing to decide.
    function test_AfterHandoverTheChainsAccusationStillRipens() public {
        _handOverRemovalRight(address(0xDA0));
        _threeOverturnsOnDistinctDisputes(arbiter);

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));
    }

    /// The timeout road lays down a DIFFERENT cause — Timeouts, not OverturnedVerdicts.
    /// A second guard on the mirror of the codes: the expectation again comes from
    /// another enum.
    function test_TheTimeoutPathAccusesWithTimeouts() public {
        _disputeAndOverturn(address(0x9C1), address(0x9C2));
        _disputeAndOverturn(address(0x9C3), address(0x9C4));

        address agr = _fundedDisputeClaimedBy(address(0x9C5), address(0x9C6));
        vm.warp(vm.getBlockTimestamp() + 4 days + 1);
        vm.prank(address(0x9C5));
        Agreement(agr).triggerArbiterTimeout();

        (uint8 cause, , , address by, bool live) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertTrue(live, "a timeout accuses too");
        assertEq(by, address(0), "and also in nobody's name");
        assertEq(
            cause, uint8(ArbiterAccountabilityFacet.Cause.Timeouts),
            "the timeout road must be recorded as the cause Timeouts and not as overturns"
        );
        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "and the seat survives too: the road has nothing to do with it"
        );
    }

    /// ⚠️ A TIMEOUT MUST LEAVE A RECORD NAMING THE ARBITER (round of edits 1,
    /// 21 August 2026).
    ///
    /// Before this, the FIRST and SECOND timeouts left nothing on chain that a
    /// reader could address by arbiter: notifyArbiterTimeout emitted nothing at
    /// all, and Agreement.ArbiterTimedOut(address indexed client, uint256)
    /// lives on the deal and names the CLIENT. The counter grew in silence.
    ///
    /// Why that mattered: the chain's accusation stands on three disputes and
    /// only two could be recovered from the logs. The accused was shown two of
    /// the three, and the third was not "marked missing" — it was invisible.
    ///
    /// The scene takes the FIRST timeout, where no accusation exists yet and
    /// nothing else is emitted. That is the one that was mute.
    function test_TheTimeoutLeavesARecordNamingTheArbiter() public {
        address agr = _fundedDisputeClaimedBy(address(0x9E1), address(0x9E2));
        vm.warp(vm.getBlockTimestamp() + 4 days + 1);

        // Both fields are indexed and the event carries no data, so both topics
        // and the empty body are checked.
        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterRegistryFacet.ArbiterTimeoutRecorded(arbiter, agr);

        vm.prank(address(0x9E1));
        Agreement(agr).triggerArbiterTimeout();

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter),
            1,
            "the mistake was booked - otherwise there is nothing for the event to be about"
        );
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "and it is the FIRST mistake: no accusation yet, one log in the receipt"
        );
    }

    /// A run of three with a timeout in the middle is recoverable FROM THE LOGS
    /// in full — owner decision 15a, checked against the chain rather than
    /// against the indexer.
    ///
    /// The scene builds three disputes: an overturn, a timeout, an overturn.
    /// The chain's accusation will name the last; the first two have to be
    /// findable in the logs by the arbiter's address. Before the fix the middle
    /// one was findable by nothing.
    function test_TheWholeRunIsRecoverableFromLogsWithATimeoutInIt() public {
        vm.recordLogs();

        _disputeAndOverturn(address(0x9F1), address(0x9F2));

        address timedOut = _fundedDisputeClaimedBy(address(0x9F3), address(0x9F4));
        vm.warp(vm.getBlockTimestamp() + 4 days + 1);
        vm.prank(address(0x9F3));
        Agreement(timedOut).triggerArbiterTimeout();

        _disputeAndOverturn(address(0x9F5), address(0x9F6));

        (, , , , bool live) = ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertTrue(live, "three mistakes - the chain has accused");

        // Collect the disputes off the logs the way a reader does: two kinds of
        // event, and the arbiter is a topic in both.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        bool sawTimedOut;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length < 3) continue;
            bytes32 sig = logs[i].topics[0];
            bool overturn = sig == ArbiterRegistryFacet.VerdictOverturned.selector;
            bool timeout  = sig == ArbiterRegistryFacet.ArbiterTimeoutRecorded.selector;
            if (!overturn && !timeout) continue;

            // VerdictOverturned(agreement, arbiter, ...) puts the arbiter
            // second; ArbiterTimeoutRecorded(arbiter, agreement) puts him first.
            address who = address(uint160(uint256(overturn ? logs[i].topics[2] : logs[i].topics[1])));
            if (who != arbiter) continue;

            found++;
            if (timeout && address(uint160(uint256(logs[i].topics[2]))) == timedOut) sawTimedOut = true;
        }

        assertEq(found, 3, "all three disputes of the run must be readable from the logs");
        assertTrue(sawTimedOut, "and the middle one is the timeout");
    }

    /// The shared part for the timeout scenes: a deal driven to a claimed dispute.
    function _fundedDisputeClaimedBy(address cli, address exec) internal returns (address agr) {
        usdc.mint(cli, 1_000_000 * 10 ** 6);
        vm.prank(cli);
        usdc.approve(address(diamond), 10 * 10 ** 6);
        vm.prank(address(diamond));
        agr = FactoryFacet(address(diamond)).deployAgreement(cli, exec, arbiter, AMOUNT, DEADLINE, TERMS, 0);
        vm.prank(cli);
        usdc.approve(agr, AMOUNT);
        vm.prank(cli);
        Agreement(agr).fund();
        vm.prank(exec);
        Agreement(agr).activate();
        vm.prank(cli);
        Agreement(agr).raiseDispute();
        _claimDisputeAs(agr, arbiter);
    }

    /// ⚠️ A VINDICATION BY THE PANEL QUENCHES THE CHAIN'S ACCUSATION.
    ///
    /// Worked out in review, not assumed. Three mistakes → a suspension and an
    /// accusation, the counter at 3. The panel vindicates the arbiter on one of the
    /// disputes (resolveAppeal on top of a MANUAL overturn turns it back to the
    /// arbiter's own verdict) → one is subtracted, 3 → 2. And MISTAKE_THRESHOLD equals
    /// TWO — so the accusation would have stayed executable, and after 48 hours an
    /// outsider would have removed a person the panel found to be right. And the door
    /// is nobody's: there is nobody to hold to account.
    function test_PanelVindicationQuenchesTheChainAccusation() public {
        address v1 = address(0x7B1);
        address v2 = address(0x7B2);
        address v3 = address(0x7B3);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v1);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v2);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v3);

        // Two mistakes on two disputes, and a third on the dispute that is appealed.
        _disputeAndOverturn(address(0x9D1), address(0x9D2));
        _disputeAndOverturn(address(0x9D3), address(0x9D4));
        address agr = _disputeAndOverturn(address(0x9D5), address(0x9D6));

        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "setup: the chain has accused"
        );
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter));

        // The losing side appeals the MANUAL overturn. The panel votes to overturn —
        // and restores the arbiter's own verdict.
        // It is the LOSING side that appeals. _disputeAndOverturn submits a verdict in
        // the client's favour and overturns it by hand in the executor's — so the
        // client lost, and the appeal is theirs.
        usdc.mint(address(0x9D5), 100 * 10 ** 6);
        vm.prank(address(0x9D5));
        usdc.approve(address(diamond), 20 * 10 ** 6);
        vm.prank(address(0x9D5));
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.prank(v1);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);

        vm.expectEmit(true, true, false, false, address(diamond));
        emit ArbiterRegistryFacet.ChainAccusationCleared(arbiter, agr);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "the chain's accusation is cleared: the chain took back its own word"
        );
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "and the counter is zeroed: otherwise one overturn would accuse again"
        );
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "and the suspension is lifted: a vindicated arbiter does not sit locked up"
        );
        assertTrue(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));

        // And there is nothing left to press the button with.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        vm.expectRevert(ArbiterAccountabilityFacet.NoLiveProposal.selector);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);
    }

    /// The reverse half of the same trap: the panel does NOT quench A HUMAN accusation.
    /// It said its word about one dispute and not about the collusion somebody else
    /// alleged; otherwise every accused arbiter would clean their record with an appeal
    /// on an unrelated verdict.
    function test_PanelVindicationLeavesAHumanAccusationStanding() public {
        address v1 = address(0x7C1);
        address v2 = address(0x7C2);
        address v3 = address(0x7C3);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v1);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v2);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v3);

        address agr = _disputeAndOverturn(address(0x9E1), address(0x9E2));

        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST,
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        (, , uint256 before, address by0, ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);

        usdc.mint(address(0x9E1), 100 * 10 ** 6);
        vm.prank(address(0x9E1));
        usdc.approve(address(diamond), 20 * 10 ** 6);
        vm.prank(address(0x9E1));
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.prank(v1);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        (, , uint256 afterTs, address by1, bool live) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertTrue(live, "the human accusation is alive");
        assertEq(afterTs, before, "its clock is untouched");
        assertEq(by1, by0, "and so is its accuser");
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "the single mistake was taken off by the subtraction, but that is ALL that was done"
        );
    }

    /// The chief does not silence the fast lever of the automatic road with ONE
    /// transaction. Before the change this rested on `removedAt != 0`; the removal moved
    /// two days forward, and the discriminator gained a second half — "an accusation by
    /// THE CHAIN hangs against them".
    function test_ChiefCannotLiftTheChainSuspensionWhileTheAccusationStands() public {
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        _threeOverturnsOnDistinctDisputes(arbiter);

        vm.prank(CHIEF);
        vm.expectRevert(ArbiterAccountabilityFacet.RemovalSuspensionIsRemovalAuthorityOnly.selector);
        ArbiterAccountabilityFacet(address(diamond)).liftSuspension(arbiter);

        assertTrue(ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter));
    }

    /// ...but they are not locked out either: withdrawing the accusation in their own
    /// name, they lift the suspension in the ordinary way. Two transactions instead of
    /// one silent one.
    function test_ChiefLiftsTheSuspensionAfterWithdrawingTheAccusation() public {
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        _threeOverturnsOnDistinctDisputes(arbiter);

        vm.prank(CHIEF);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);
        vm.prank(CHIEF);
        ArbiterAccountabilityFacet(address(diamond)).liftSuspension(arbiter);

        assertFalse(ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter));
    }

    /// ⚠️ THE MANUAL DOOR SPENDS THE EVIDENCE TOO — new behaviour, and without this
    /// scene it would have been changed SILENTLY (measured: removing the zeroing in
    /// `_performRemoval` gave three reds, and all three on the CHAIN's road).
    ///
    /// What is fixed. `_requireProven` proves OverturnedVerdicts by reading
    /// `arbiterMistakeStreak`, and the counter used to survive a manual removal — that
    /// stood written in its own docstring as a known defect: an owner who returned a
    /// mistakenly removed arbiter through addArbiter returned them TOGETHER with the
    /// counter at the threshold, and that same evidence justified a repeat removal
    /// without a single new mistake. Both doors now zero it with one line of the shared
    /// removal body.
    function test_RemovalForCauseSpendsTheEvidenceItWasBuiltOn() public {
        _disputeAndOverturn(address(0x9F1), address(0x9F2));
        _disputeAndOverturn(address(0x9F3), address(0x9F4));
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 2,
            "setup: two real overturns, exactly the threshold of a MANUAL removal"
        );

        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0));
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "the evidence is spent by the removal built on it"
        );

        // And the second half, which is the point of it all: somebody returned by the
        // owner is NO LONGER one step from a repeat removal on THE SAME evidence. The
        // refusal comes at execution and not at the proposal: the cause is proved by
        // `_requireProven`, which is called from removeArbiterForCause — a proposal
        // checks only the form (a digest and words for the non-attested codes).
        ArbiterRegistryFacet(address(diamond)).addArbiter(arbiter);
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbiterAccountabilityFacet.CauseNotProven.selector,
                uint8(ArbiterAccountabilityFacet.Cause.OverturnedVerdicts)
            )
        );
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );
    }

    // ============================================================
    //  WHAT A REVIEW FOUND ON THE QUIET DOOR
    //
    //  Four findings, and all four about what had been built NOT BEING GUARDED: the
    //  removal event (remove the emit — 0 red out of 924), a silent lifting of the
    //  suspension, a stale accusation locking somebody out forever, and an error in a
    //  proposed withdrawal condition that nobody would have noticed.
    // ============================================================

    /// ⚠️ THE REMOVAL EVENT IN ITS NEW PLACE AND WITH NEW FIELDS. The review's
    /// measurement: remove `emit ArbiterDemoted` from `executeChainRemoval` entirely —
    /// ZERO red out of 924. The event moved to another moment and changed all three of
    /// its fields, and not one scene saw it.
    ///
    /// All three are checked:
    ///   • `by == address(0)` — whoever pressed is not named, the accuser here is the
    ///     chain;
    ///   • `path` — the SAVED `chainProposalPath`, which the storage field exists for
    ///     (at the moment of the removal there is nowhere else to take the road from);
    ///   • `agreement == address(0)` — by this moment there is no deal "on which they
    ///     were removed": the cause is a streak. The one that tipped it was named by
    ///     `RemovalProposedByChain` two days earlier.
    function test_ChainRemovalAnnouncesTheDemotionNamingNobody() public {
        _threeOverturnsOnDistinctDisputes(arbiter);
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ArbiterRegistryFacet.ArbiterDemoted(
            arbiter,
            address(0),
            ArbiterRegistryFacet.DemotionPath.OwnerOverturn,
            address(0)
        );
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);
    }

    /// The second half of the same lock, and it is about ONE field: `path` must arrive
    /// from storage rather than being nailed to one value. The scene differs from its
    /// neighbour exactly by the road — a timeout instead of an overturn — and a nailed
    /// `OwnerOverturn` would go red here while staying green there.
    function test_TheSavedPathSurvivesTheTwoDaysToTheRemoval() public {
        _disputeAndOverturn(address(0xAB1), address(0xAB2));
        _disputeAndOverturn(address(0xAB3), address(0xAB4));

        address agr = _fundedDisputeClaimedBy(address(0xAB5), address(0xAB6));
        vm.warp(vm.getBlockTimestamp() + 4 days + 1);
        vm.prank(address(0xAB5));
        Agreement(agr).triggerArbiterTimeout();

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());

        vm.expectEmit(true, true, true, true, address(diamond));
        emit ArbiterRegistryFacet.ArbiterDemoted(
            arbiter,
            address(0),
            ArbiterRegistryFacet.DemotionPath.AgreementTimeout,
            address(0)
        );
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);
    }

    /// ⚠️ LIFTING A SUSPENSION IS ANNOUNCED. The vindication branch erased
    /// `suspendedUntil` silently, and in the feed the suspension looked as if it had
    /// never ended: every other end of it is visible — `liftSuspension` sends an event,
    /// and the expiry of 72 hours is read from the term that has lain in the log since
    /// the moment it was imposed.
    ///
    /// `by` is zero: it was THE PANEL that decided, and there is no hand here.
    function test_VindicationAnnouncesTheLiftedSuspension() public {
        address v1 = address(0xAC1);
        address v2 = address(0xAC2);
        address v3 = address(0xAC3);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v1);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v2);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v3);

        _disputeAndOverturn(address(0xAD1), address(0xAD2));
        _disputeAndOverturn(address(0xAD3), address(0xAD4));
        address agr = _disputeAndOverturn(address(0xAD5), address(0xAD6));
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "setup: the suspension is standing"
        );

        usdc.mint(address(0xAD5), 100 * 10 ** 6);
        vm.prank(address(0xAD5));
        usdc.approve(address(diamond), 20 * 10 ** 6);
        vm.prank(address(0xAD5));
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.prank(v1);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);

        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterAccountabilityFacet.ArbiterSuspensionLifted(arbiter, address(0));
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertFalse(ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter));
    }

    /// ⚠️ A STALE ACCUSATION LOCKS NOTHING.
    ///
    /// The predicate "an accusation by the chain hangs against them" was the only one
    /// of the four in the facet that did not look at `PROPOSAL_TTL`. The price: an
    /// accusation nobody executed goes stale in 14 days and stops hanging — but the
    /// chief permanently lost the right to lift an ORDINARY suspension from that
    /// person, one they had imposed themselves and for an entirely different reason.
    function test_AStaleChainAccusationLocksNothing() public {
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        _threeOverturnsOnDistinctDisputes(arbiter);

        // The accusation went stale by itself; nobody pressed the button.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getProposalTTL());
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "setup: the accusation is no longer alive"
        );
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "setup: and the automatic suspension expired by itself long ago"
        );

        // An ordinary suspension, for its own reason, by the chief's hand.
        vm.prank(CHIEF);
        ArbiterAccountabilityFacet(address(diamond)).suspendArbiter(arbiter);
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter));

        // And they must be able to lift it: that is their job, a light measure.
        vm.prank(CHIEF);
        ArbiterAccountabilityFacet(address(diamond)).liftSuspension(arbiter);
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter),
            "a dead record has no right to take the chief's ordinary door away"
        );
    }

    /// ⚠️ A LOCK ON AN ERROR THAT WAS VERY NEARLY TAKEN FROM THE BRIEF. The proposed
    /// withdrawal condition was `p.by != address(0) && msg.sender != p.by` — and an
    /// EMPTY record has a zero `by` too, so the chief, acting against a person nobody
    /// had laid anything against, would have PASSED instead of being refused. The
    /// review's measurement: substitute that line literally — ZERO red out of 924.
    ///
    /// The refusal here is not about the role (the chief passed that) but about there
    /// being nothing to withdraw and the record not being theirs. The chain-accusation
    /// withdrawal branch requires `proposedAt != 0` for exactly that reason.
    function test_ChiefCannotWithdrawAgainstAnEmptyRecord() public {
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "setup: nothing lies against them"
        );

        vm.prank(CHIEF);
        vm.expectRevert(ArbiterAccountabilityFacet.NotYourProposal.selector);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);
    }

    /// The reverse half: an empty record does not refuse THE HOLDER OF THE RIGHT — they
    /// pass higher up the branch and quietly do nothing, with no event in the feed (an
    /// empty withdrawal would read as "there was something against them").
    function test_AuthorityWithdrawingNothingIsSilentNotRefused() public {
        vm.recordLogs();
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != ArbiterAccountabilityFacet.RemovalProposalWithdrawn.selector,
                "an empty withdrawal must leave no trace in the feed"
            );
        }
    }

    // ============================================================
    //  AN ACCUSATION IS CANCELLED BY PROOF OF ERROR, NOT BY GOOD WORK AFTERWARDS
    //  (the owner's decision, 18 August 2026)
    //
    //  The button used to ask the counter AFRESH, and `finalizeVerdict` zeroes it on a
    //  clean verdict. So an arbiter against whom the chain had already opened a case
    //  sat out the suspension, took any dispute, carried it through cleanly — and the
    //  button answered CauseNotProven. The case meanwhile did not die: it hung for 14
    //  days, locking resignation. Neither removed nor free — the worst of the two.
    //
    //  It became: the record the chain laid down IS the proof. It was made at the
    //  moment the facts happened. Exactly four things cancel it, and both scenes below
    //  are about the boundary between them.
    // ============================================================

    /// The first: good work AFTER the accusation does not cancel it.
    function test_CleanWorkAfterTheChargeDoesNotCancelIt() public {
        _threeOverturnsOnDistinctDisputes(arbiter);
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter));

        // The suspension expires by itself — 72 hours. The accusation is alive: it has 14 days.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getSuspensionWindow());
        assertFalse(ArbiterAccountabilityFacet(address(diamond)).isSuspended(arbiter));

        // And they take a dispute and carry it through CLEANLY. finalizeVerdict zeroes
        // the judging-mistake counter — the very one the cause was proved with.
        address agr = _disputeAndSubmit(address(0xB01), address(0xB02));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(agr);
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0,
            "setup: a clean verdict zeroed the counter, and the old evidence no longer reads"
        );

        // The button must fire all the same: the proof was THE PROPOSAL recorded by the
        // chain then, and not the state of the counter today.
        vm.prank(STRANGER);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertFalse(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "you did it, you answer for it: good work afterwards does not cancel an accusation"
        );
    }

    /// The second, and it matters more than the first: the change must not have turned
    /// "a case does not expire by itself" into "a case cannot be cancelled by
    /// anything". A vindication by the panel quenches the accusation entirely, and
    /// there is nothing to press afterwards.
    ///
    /// It differs from test_PanelVindicationQuenchesTheChainAccusation in checking not
    /// the state but the CONSEQUENCE for the button now that the re-checking of the
    /// cause has been taken out of it: were the quenching to break, the button would
    /// now fire on a vindicated person in silence.
    function test_ThePanelStillDisarmsTheButtonAfterTheProofCheckIsGone() public {
        address v1 = address(0xB11);
        address v2 = address(0xB12);
        address v3 = address(0xB13);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v1);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v2);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v3);

        _disputeAndOverturn(address(0xB21), address(0xB22));
        _disputeAndOverturn(address(0xB23), address(0xB24));
        address agr = _disputeAndOverturn(address(0xB25), address(0xB26));
        assertTrue(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter));

        usdc.mint(address(0xB25), 100 * 10 ** 6);
        vm.prank(address(0xB25));
        usdc.approve(address(diamond), 20 * 10 ** 6);
        vm.prank(address(0xB25));
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.prank(v1);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        vm.expectRevert(ArbiterAccountabilityFacet.NoLiveProposal.selector);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "the panel said they were right, and the button against them is gone"
        );
    }

    /// And the third boundary of the same decision: a withdrawal by the owner or the
    /// chief also disarms the button. Together with going stale and with execution,
    /// those are all four ways of quenching an accusation listed in the button's
    /// docstring.
    function test_WithdrawalDisarmsTheButtonToo() public {
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        _threeOverturnsOnDistinctDisputes(arbiter);

        vm.prank(CHIEF);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);

        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());
        vm.prank(STRANGER);
        vm.expectRevert(ArbiterAccountabilityFacet.NoLiveProposal.selector);
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);
    }

    // ============================================================
    //  A FIFTH EXIT AND A DEAD ACCUSATION
    //
    //  Both were found by probing on a live diamond, and both erased the very thing
    //  storage fields had been spent on.
    // ============================================================

    /// ⚠️ THE FIFTH EXIT: the holder of the right executed THE CHAIN's accusation
    /// through their own door. `removeArbiterForCause` read the record and did not look
    /// at `by` at all — there was no reverse guard to `NotAChainProposal`. The removal
    /// went through, and the eternal record CHANGED ITS ORIGIN: `lastRemovalCause` 253
    /// ("the chain, over overturns") turned into 1 ("a human, for cause"), and in the
    /// feed `ArbiterDemoted(by = 0)` was replaced by
    /// `ArbiterRemovedForCause(by = the owner)`.
    ///
    /// Two storage fields — `chainProposalPath` and `lastRemovalCause` — exist for
    /// exactly that distinction, and one call erased it.
    function test_TheAuthorityCannotExecuteTheChainsAccusationHimself() public {
        _threeOverturnsOnDistinctDisputes(arbiter);
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getRemovalDelay());

        vm.expectRevert(ArbiterAccountabilityFacet.ChainProposalNeedsTheChainDoor.selector);
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.OverturnedVerdicts, bytes32(0), address(0), ""
        );

        assertTrue(
            ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter),
            "and nothing happened behind the refusal"
        );

        // Nothing is lost: they can press the chain's button themselves, like anybody
        // else — and then the record will tell the truth about the origin.
        ArbiterAccountabilityFacet(address(diamond)).executeChainRemoval(arbiter);
        (, , , , , , , , , , , , , uint8 cause) =
            ArbiterAccountabilityFacet(address(diamond)).getArbiterStanding(arbiter);
        assertEq(cause, AUTO_OVERTURN, "the provenance is kept: it was THE CHAIN that removed them, not they themselves");
    }

    /// The reverse side of the same pair: A HUMAN accusation still goes through its own
    /// door and is untouched by any new check.
    function test_TheAuthorityStillExecutesAHumanAccusation() public {
        _proposeAndWait(arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST);
        ArbiterAccountabilityFacet(address(diamond)).removeArbiterForCause(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST, address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        assertFalse(ArbiterRegistryFacet(address(diamond)).isRegisteredArbiter(arbiter));
    }

    /// ⚠️ A DEAD ACCUSATION QUENCHES NOTHING. The vindication branch looked at
    /// `proposedAt != 0` without `PROPOSAL_TTL` — the same defect as the one a line
    /// below. The price: an accusation that had gone stale two weeks earlier and was
    /// executable by nobody erased the counter ENTIRELY, against the "exactly one
    /// mistake is taken off" rule seven lines above, demolished the record itself and
    /// sent `ChainAccusationCleared` about something long dead.
    ///
    /// The scene is built so that the dead record STAYS dead and nobody covers it with
    /// a live one: after it goes stale the counter is reset by a clean verdict, and the
    /// next two mistakes do not reach the automatic threshold.
    function test_ADeadChainAccusationDoesNotSwallowTheWholeStreak() public {
        address v1 = address(0xC01);
        address v2 = address(0xC02);
        address v3 = address(0xC03);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v1);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v2);
        ArbiterRegistryFacet(address(diamond)).addArbiter(v3);

        _threeOverturnsOnDistinctDisputes(arbiter);
        (, , uint256 deadAt, , ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertGt(deadAt, 0, "setup: the chain's accusation is laid down");

        // Nobody pressed — the accusation died of old age, but THE RECORD REMAINED:
        // a stale one does not erase itself.
        vm.warp(vm.getBlockTimestamp() + ArbiterAccountabilityFacet(address(diamond)).getProposalTTL());
        assertFalse(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter));

        // A clean verdict zeroes the streak — the automatic threshold is now far off,
        // and a new accusation by the chain will not land on top of the dead one.
        address clean = _disputeAndSubmit(address(0xC21), address(0xC22));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        ArbiterRegistryFacet(address(diamond)).finalizeVerdict(clean);
        assertEq(ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 0);

        // Two manual mistakes: the streak equals two, the automatic threshold is not reached.
        _disputeAndOverturn(address(0xC31), address(0xC32));
        address agr = _disputeAndOverturn(address(0xC33), address(0xC34));
        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 2,
            "setup: two mistakes, and no new accusation from the chain"
        );
        assertFalse(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter));

        // The panel vindicates on the second — EXACTLY ONE is taken off.
        usdc.mint(address(0xC33), 100 * 10 ** 6);
        vm.prank(address(0xC33));
        usdc.approve(address(diamond), 20 * 10 ** 6);
        vm.prank(address(0xC33));
        ArbiterRegistryFacet(address(diamond)).raiseAppeal(agr);
        vm.prank(v1);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v2);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, true);
        vm.prank(v3);
        ArbiterRegistryFacet(address(diamond)).voteOnAppeal(agr, false);
        ArbiterRegistryFacet(address(diamond)).resolveAppeal(agr);

        assertEq(
            ArbiterAccountabilityFacet(address(diamond)).getArbiterMistakeStreak(arbiter), 1,
            "EXACTLY ONE mistake is taken off: a dead record has no right to clear anything"
        );

        (, , uint256 stillDeadAt, , ) =
            ArbiterAccountabilityFacet(address(diamond)).getRemovalProposal(arbiter);
        assertEq(
            stillDeadAt, deadAt,
            "and the vindication does not touch the dead record itself: there is nothing to clear"
        );
    }

    // ============================================================
    //  THE RATCHET REACHES THE WITHDRAWAL DOOR
    //
    //  An earlier round wrote in a docstring that after the handover only the successor
    //  may withdraw. The code did not hold that: `_requireOwnerOrChief` gates THE CHIEF
    //  and admits the owner ALWAYS, and the `chainLaid` branch never reaches
    //  `NotYourProposal`. So a former owner quenched automatic accusations against any
    //  arbiter indefinitely — precisely the remnant of power the ratchet was built to
    //  remove, and asymmetrically at that: the chief already lost this door while the
    //  DAO is active.
    //
    //  The owner's decision was to fix it in code. The form is taken from proposeRemoval.
    // ============================================================

    /// ⚠️ THE DIRECT SIDE: after the handover a former owner does NOT quench the chain's accusation.
    function test_OwnerCannotWithdrawTheChainAccusationAfterHandover() public {
        address dao = address(0xDA0);
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);
        _threeOverturnsOnDistinctDisputes(arbiter);
        _handOverRemovalRight(dao);

        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);

        // And neither does the chief: after the handover the door belongs to one.
        vm.prank(CHIEF);
        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);

        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "the chain's accusation is in place: there is nobody left to clear it but the successor"
        );

        // But the successor does, and this is not a door without an opener.
        vm.prank(dao);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);
        assertFalse(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter));
    }

    /// ⚠️ THE COUNTERPART: BEFORE the handover nothing changed. Without it the fix could
    /// have repaired the ratchet while breaking the present day — and today there is no
    /// handover, and both must be able to quench rigged overturns.
    function test_BeforeHandoverOwnerAndChiefWithdrawAsBefore() public {
        ArbiterRegistryFacet(address(diamond)).setChiefArbiter(CHIEF);

        // The owner.
        _threeOverturnsOnDistinctDisputes(arbiter);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "before the handover the owner clears it, as they always did"
        );

        // The chief, on a fresh accusation against THE SAME arbiter. The cause is
        // Collusion — the chain does not verify it, the judging-mistake counter has
        // nothing to do with it, and the scene needs no second arbiter.
        vm.prank(CHIEF);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            arbiter, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST,
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        vm.prank(CHIEF);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(arbiter);
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(arbiter),
            "before the handover the chief withdraws their own, as they always did"
        );
    }

    /// ⚠️ WHAT THE OWNER KEEPS AFTER THE HANDOVER — a scene introduced because the
    /// `_requireOwnerOrChief` docstring asserts this AS A NUMBER while the number had
    /// not one guard. The count has already changed twice (four → three, then three →
    /// two), and both times in silence.
    ///
    /// Today, of the four doors that went under `onlyOwnerOrChief`, the owner keeps TWO
    /// after the handover, and both are light:
    ///   • `suspendArbiter` — reversible, expiring by itself;
    ///   • the LIGHT branch of `liftSuspension` — lifting an ordinary suspension.
    /// And they lose two heavy ones: `proposeRemoval` and `withdrawProposal`, both
    /// through `RemovalHandedOver`.
    function test_AfterHandoverTheOwnerKeepsExactlyTheTwoLightDoors() public {
        address dao = address(0xDA1);
        address subject = address(0xD21);
        ArbiterRegistryFacet(address(diamond)).addArbiter(subject);
        _handOverRemovalRight(dao);

        // ── Keeps: suspending ──
        ArbiterAccountabilityFacet(address(diamond)).suspendArbiter(subject);
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(subject),
            "the light measure stays with the owner even after the handover"
        );

        // ── Keeps: lifting an ORDINARY suspension (there is no removal on the person,
        //    and no accusation by the chain either) ──
        ArbiterAccountabilityFacet(address(diamond)).liftSuspension(subject);
        assertFalse(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(subject),
            "and so does lifting it: that is their job and it is not about removal"
        );

        // ── Loses: proposing a removal ──
        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            subject, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST,
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );

        // ── Loses: withdrawing ──
        vm.prank(dao);
        ArbiterAccountabilityFacet(address(diamond)).proposeRemoval(
            subject, ArbiterAccountabilityFacet.Cause.Collusion, DIGEST,
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        vm.expectRevert(ArbiterAccountabilityFacet.RemovalHandedOver.selector);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(subject);

        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(subject),
            "and the successor's record outlives it"
        );

        // ── AND WHAT THE SUCCESSOR HAS: they withdraw their own and somebody else's ──
        vm.prank(dao);
        ArbiterAccountabilityFacet(address(diamond)).withdrawProposal(subject);
        assertFalse(ArbiterAccountabilityFacet(address(diamond)).hasLiveProposal(subject));

        // ── ⚠️ AND WHAT THEY DO NOT HAVE: they cannot lift an ORDINARY suspension.
        //    The light branch of liftSuspension goes under _requireOwnerOrChief, and
        //    that, while the DAO is active, sees neither the chief nor governance
        //    itself — only the owner.
        ArbiterAccountabilityFacet(address(diamond)).suspendArbiter(subject);
        vm.prank(dao);
        vm.expectRevert(ArbiterAccountabilityFacet.NotOwnerOrChief.selector);
        ArbiterAccountabilityFacet(address(diamond)).liftSuspension(subject);
        assertTrue(
            ArbiterAccountabilityFacet(address(diamond)).isSuspended(subject),
            "the remainder: the owner freezes, and governance does not unfreeze"
        );
    }
}
