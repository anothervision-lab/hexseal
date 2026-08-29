// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Applications for a seat in the arbiter corps.
//
// The whole mechanism exists because the automatic door cannot open at the
// start: `applyAsArbiter` measures a RECORD, and on a marketplace nobody has
// been using yet there is no record to measure. So a person decides, by hand,
// until governance is live — and the ratchet takes the door away at that
// moment, not at somebody's discretion.
//
// ⚠️ THE RIG IS A WHOLE DIAMOND, not a bare facet, and it has to be. Three
// things this facet does are invisible on a standalone contract:
//
//   * it asks the REGISTRY for `isDaoActive()` and `getChiefBloc()` through
//     `address(this)`, which is the diamond only when there is one;
//   * it asks the ACCOUNTABILITY facet for the words cap the same way;
//   * it writes fields (`isArbiter`, `arbiterList`, `arbiterBond`, `seatedBy`)
//     that other facets read, and two separately deployed facets have two
//     separate storages at the same namespace offset — a write through one and
//     a read through the other would come back a clean zero and look like an
//     answer.
//
// The cuts are built by `DeployFull`'s own builders rather than by a second
// hand-written list here: a private list would drift from the live layout in
// silence, and then these scenes would prove something about a diamond that
// does not exist.
//
// ⚠️ Time is read through `vm.getBlockTimestamp()`, never `block.timestamp`:
// under via_ir solc treats TIMESTAMP as constant within one call, so a second
// warp in the same test body would land on the same second as the first.

import "forge-std/Test.sol";
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
import {MinimalForwarder} from "../src/MinimalForwarder.sol";
import "../script/DeployFull.s.sol";

contract MockUSDCApplications {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function burnFrom(address from, uint256 amount) external { balanceOf[from] -= amount; }

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

contract ArbiterApplicationsTest is Test {
    DiamondProxy diamond;
    DeployFull   deploy;
    MockUSDCApplications usdc;
    MinimalForwarder forwarder;

    ArbiterApplicationsFacet   app;
    ArbiterRegistryFacet       reg;
    ArbiterAccountabilityFacet acc;
    ReputationFacet            rep;

    address owner;
    address chief;
    address stranger;
    address daoSuccessor;

    /// The applicant with a known private key — the two gasless doors are
    /// driven through a real forwarder, and that needs a signer.
    uint256 constant APPLICANT_PK = 0xA99;
    address applicant;

    /// Namespace base of ReputationStorage. Its `xp` is field 0 and its
    /// `cleanStreak` is field 9 — but the numbers are not taken on trust: the
    /// seeding helper writes and then reads back through the live getters, so a
    /// layout that moves turns the SETUP red rather than quietly seeding
    /// nothing and letting a scene pass for the wrong reason.
    bytes32 constant REP_BASE = 0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400;
    uint256 constant SLOT_XP           = 0;
    uint256 constant SLOT_CLEAN_STREAK = 9;
    /// `uniqueActiveUsers` is field 8 of the same struct — the offset four
    /// other test files pin by brute force against the live getter.
    uint256 constant SLOT_UNIQUE_ACTIVE_USERS = 8;

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    /// The literal seven days, written out here and NOWHERE derived from the
    /// contract. Every deadline scene below warps by this and not by
    /// `getApplicationWindow()`: a test that asks the contract how long its own
    /// window is and then checks the window against that answer is a test that
    /// agrees with itself no matter what the number becomes.
    uint256 constant WINDOW = 7 days;

    /// States as the facet numbers them. Literals, for the same reason.
    uint8 constant ST_NONE      = 0;
    uint8 constant ST_PENDING   = 1;
    uint8 constant ST_APPROVED  = 2;
    uint8 constant ST_REJECTED  = 3;
    uint8 constant ST_WITHDRAWN = 4;
    uint8 constant ST_EXPIRED   = 5;

    string constant REFUSAL = "took three disputes of the same counterparty and ruled for him three times";

    function setUp() public {
        owner        = address(this);
        chief        = address(0xC4);
        stranger     = address(0x5A);
        daoSuccessor = address(0xDA0);
        applicant    = vm.addr(APPLICANT_PK);

        usdc      = new MockUSDCApplications();
        forwarder = new MinimalForwarder();
        deploy    = new DeployFull();

        DiamondCutFacet   cutFacet   = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet    ownFacet   = new OwnershipFacet();
        RegistryFacet     regFacet   = new RegistryFacet();
        FactoryFacet      facFacet   = new FactoryFacet();

        IDiamondCut.FacetCut[] memory initCuts = deploy.buildInitCuts(
            address(cutFacet), address(loupeFacet), address(ownFacet), address(regFacet), address(facFacet)
        );
        diamond = new DiamondProxy(owner, initCuts, address(0), "");

        IDiamondCut.FacetCut[] memory rest = deploy.buildRemainingCuts(
            address(new JobBoardFacet()),
            address(new ServiceBoardFacet()),
            address(new ArbiterRegistryFacet()),
            address(new ArbiterAccountabilityFacet()),
            address(new ArbiterApplicationsFacet()),
            address(new DealMetadataFacet()),
            address(new JobReceiptFacet()),
            address(new ReputationFacet())
        );
        IDiamondCut(address(diamond)).diamondCut(rest, address(0), "");

        RegistryFacet(address(diamond)).initRegistry(address(diamond));
        Agreement impl = new Agreement();
        FactoryFacet(address(diamond)).initFactory(
            address(usdc),
            address(0xFEE),
            address(forwarder),
            address(diamond),
            address(new AgreementDeployer(address(diamond), address(impl)))
        );

        app = ArbiterApplicationsFacet(address(diamond));
        reg = ArbiterRegistryFacet(address(diamond));
        acc = ArbiterAccountabilityFacet(address(diamond));
        rep = ReputationFacet(address(diamond));

        // Eligible by record from the start; scenes that need him ineligible
        // take it away explicitly, so nothing depends on a default.
        _seedRecord(applicant, 3_000, 10);
        usdc.mint(applicant, 500_000_000);
    }

    // ══════════════════════════════════════════════════════════════════════
    // MIRRORS — every expected value below comes from the REGISTRY, not from
    // the facet under test and not from a literal in the facet under test.
    // A mirror checked against its own file is a lock looking in a mirror.
    // ══════════════════════════════════════════════════════════════════════

    /// The XP threshold has a live getter on the registry, so the oracle is as
    /// direct as it gets.
    function test_MinXpMirrorMatchesRegistry() public view {
        (uint256 minXP, , , ) = app.getApplicationRequirements();
        assertEq(minXP, reg.getMinXPToRegister(), "the XP mirror drifted from the registry");
    }

    /// The streak threshold is `private` over there and has no getter, so the
    /// oracle is the registry's own refusal: `InsufficientCleanStreak` carries
    /// the number it required.
    function test_MinCleanStreakMirrorMatchesRegistryRefusal() public {
        (, uint256 minStreak, , ) = app.getApplicationRequirements();
        _activateDao();

        address candidate = address(0xC0FFEE);
        _seedRecord(candidate, 3_000, minStreak - 1);

        vm.prank(candidate);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterRegistryFacet.InsufficientCleanStreak.selector, minStreak - 1, minStreak
        ));
        reg.applyAsArbiter();
    }

    /// The bond is `private` over there too. The oracle is the money: a
    /// successful `applyAsArbiter` moves exactly as much USDC as this facet
    /// says it will. A larger real bond fails on the allowance; a smaller one
    /// moves a different amount. Either way this goes red.
    function test_ArbiterBondMirrorMatchesWhatTheRegistryActuallyTakes() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _activateDao();

        address candidate = address(0xB0AD);
        _seedRecord(candidate, 3_000, 10);
        usdc.mint(candidate, bond);

        uint256 heldBefore = usdc.balanceOf(address(diamond));

        vm.prank(candidate);
        usdc.approve(address(diamond), bond);
        vm.prank(candidate);
        reg.applyAsArbiter();

        assertEq(usdc.balanceOf(candidate), 0, "the registry took a different amount than the mirror says");
        assertEq(
            usdc.balanceOf(address(diamond)) - heldBefore, bond,
            "the diamond received a different amount than the mirror says"
        );
    }

    /// The appeal-deciding majority is `private` over there and reaches this
    /// facet only as a mirror. The oracle is the registry refusing `addArbiter`
    /// and naming the number in `ChiefBlocWouldDecideAppeal`.
    function test_AppealDecidingVotesMirrorMatchesRegistryRefusal() public {
        _setChief(chief);

        vm.prank(chief);
        reg.addArbiter(address(0xA101));
        assertEq(reg.getChiefBloc(), 1, "one seating puts the chief's bloc at one");

        // Two is the deciding majority at quorum, and the facet under test
        // carries 2 as its mirror. If the registry's number were anything else,
        // this call would either not revert at all or revert with a different
        // second argument.
        vm.prank(chief);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterRegistryFacet.ChiefBlocWouldDecideAppeal.selector, uint256(2), uint256(2)
        ));
        reg.addArbiter(address(0xA102));
    }

    /// The words cap is not mirrored at all — it is asked of the facet that
    /// owns it, through the diamond. This scene proves the two doors really do
    /// share one number rather than two that happen to agree today.
    function test_RefusalWordsUseTheSameCapAsTheRemovalDoors() public {
        uint256 cap = acc.getMaxReasonBytes();
        _submit(applicant);

        string memory tooLong = _repeat("x", cap + 1);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.ReasonTooLong.selector, cap + 1
        ));
        app.rejectArbiterApplication(applicant, tooLong);

        // And exactly at the cap it goes through.
        app.rejectArbiterApplication(applicant, _repeat("x", cap));
        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_REJECTED, "words exactly at the cap are accepted");
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 1 — a submission goes through, and it takes no money
    // ══════════════════════════════════════════════════════════════════════

    function test_1_SubmissionPassesOnRecordAndTakesNoBond() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 walletBefore  = usdc.balanceOf(applicant);
        uint256 diamondBefore = usdc.balanceOf(address(diamond));

        vm.expectEmit(true, false, false, true, address(diamond));
        emit ArbiterApplicationsFacet.ArbiterApplicationSubmitted(applicant, t0, t0 + WINDOW);

        vm.prank(applicant);
        app.applyForArbiterSeat();

        (uint8 state, uint256 submittedAt, uint256 expiresAt, uint256 decidedAt, address decidedBy) =
            app.getArbiterApplication(applicant);
        assertEq(state, ST_PENDING, "the application stands");
        assertEq(submittedAt, t0, "filed now");
        assertEq(expiresAt, t0 + WINDOW, "and it runs seven days");
        assertEq(decidedAt, 0, "nobody has decided it");
        assertEq(decidedBy, address(0), "and nobody is named as having decided it");

        // The whole point of the owner's decision: money does not move here.
        assertEq(usdc.balanceOf(applicant), walletBefore, "the applicant's USDC did not move");
        assertEq(usdc.balanceOf(address(diamond)), diamondBefore, "the diamond took nothing");
        assertEq(acc.getArbiterBond(applicant), 0, "and no bond is recorded against him");
        assertFalse(reg.isRegisteredArbiter(applicant), "an application is not a seat");
    }

    /// The same door through a real forwarder, signed, relayed by a third
    /// address. This is what proves the gasless half: whoever is worth seating
    /// has a record of deals, not necessarily a balance of ETH.
    function test_1b_SubmissionThroughForwarderCreditsTheHumanNotTheForwarder() public {
        _forwardFrom(APPLICANT_PK, abi.encodeWithSelector(app.applyForArbiterSeat.selector));

        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_PENDING, "the application belongs to the signer");

        (uint8 fwdState, , , , ) = app.getArbiterApplication(address(forwarder));
        assertEq(fwdState, ST_NONE, "and not to the forwarder");
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 2 — a submission is refused on record
    // ══════════════════════════════════════════════════════════════════════

    function test_2a_SubmissionRefusedOnXP() public {
        address thin = address(0x7411);
        _seedRecord(thin, 2_999, 10);

        vm.prank(thin);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterRegistryFacet.InsufficientXP.selector, uint256(2_999), uint256(3_000)
        ));
        app.applyForArbiterSeat();

        assertEq(app.getApplicantCount(), 0, "a refused submission leaves nothing in the public list");
    }

    function test_2b_SubmissionRefusedOnCleanStreak() public {
        address flaky = address(0x7412);
        _seedRecord(flaky, 10_000, 9);

        vm.prank(flaky);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterRegistryFacet.InsufficientCleanStreak.selector, uint256(9), uint256(10)
        ));
        app.applyForArbiterSeat();
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 3 — approval takes the bond exactly once and seats the man
    // ══════════════════════════════════════════════════════════════════════

    function test_3_ApprovalTakesTheBondOnceAndSeats() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _submit(applicant);
        _approveSpend(applicant, bond);

        uint256 walletBefore  = usdc.balanceOf(applicant);
        uint256 diamondBefore = usdc.balanceOf(address(diamond));

        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterApplicationsFacet.ArbiterApplicationApproved(applicant, owner, bond);

        app.approveArbiterApplication(applicant);

        assertTrue(reg.isRegisteredArbiter(applicant), "he is in the corps");
        assertEq(acc.getArbiterBond(applicant), bond, "with his bond recorded");
        assertEq(walletBefore - usdc.balanceOf(applicant), bond, "and paid out of his own wallet");
        assertEq(usdc.balanceOf(address(diamond)) - diamondBefore, bond, "into the diamond");
        assertEq(acc.getSeatedBy(applicant), owner, "seated by the person who pressed the button");

        (uint8 state, , , uint256 decidedAt, address decidedBy) = app.getArbiterApplication(applicant);
        assertEq(state, ST_APPROVED, "the application is decided");
        assertEq(decidedAt, vm.getBlockTimestamp(), "at this moment");
        assertEq(decidedBy, owner, "by this person");

        // EXACTLY ONCE. A second press must not move a second bond, and the
        // wallet is the witness rather than the state flag.
        uint256 walletAfterFirst = usdc.balanceOf(applicant);
        _approveSpend(applicant, bond); // give it every chance to move again
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.NoPendingApplication.selector, ST_APPROVED
        ));
        app.approveArbiterApplication(applicant);
        assertEq(usdc.balanceOf(applicant), walletAfterFirst, "no second bond was taken");
        assertEq(reg.getArbiters().length, 1, "and he is in the corps list exactly once");
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 4 — the bond fails, and the approver is told which half failed
    // ══════════════════════════════════════════════════════════════════════

    function test_4a_ApprovalNamesAMissingAllowance() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _submit(applicant);
        // No approve() at all — the commonest case, and the one an approver
        // must be able to tell the applicant about.

        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.BondNotApproved.selector, uint256(0), bond
        ));
        app.approveArbiterApplication(applicant);

        assertFalse(reg.isRegisteredArbiter(applicant), "a failed bond seats nobody");
        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_PENDING, "and the application is left standing, not burnt");
    }

    function test_4b_ApprovalNamesAnEmptyWallet() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _submit(applicant);
        _approveSpend(applicant, bond);
        usdc.burnFrom(applicant, usdc.balanceOf(applicant) - (bond - 1));

        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.BondBalanceTooLow.selector, bond - 1, bond
        ));
        app.approveArbiterApplication(applicant);

        assertFalse(reg.isRegisteredArbiter(applicant), "a failed bond seats nobody");
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 5 — a week later he no longer passes, so he is not seated
    // ══════════════════════════════════════════════════════════════════════

    function test_5_ApprovalRefusesWhenTheRecordWentBadWhileWaiting() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _submit(applicant);
        _approveSpend(applicant, bond);

        // He applied clean; in the days that followed a verdict of his was
        // overturned and the streak went to nothing.
        _seedRecord(applicant, 3_000, 0);

        vm.expectRevert(abi.encodeWithSelector(
            ArbiterRegistryFacet.InsufficientCleanStreak.selector, uint256(0), uint256(10)
        ));
        app.approveArbiterApplication(applicant);

        assertFalse(reg.isRegisteredArbiter(applicant), "he is not seated");
        assertEq(acc.getArbiterBond(applicant), 0, "and his money was not taken on the way to refusing him");
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 6 — seven days and the application is gone
    // ══════════════════════════════════════════════════════════════════════

    function test_6_ExpiredApplicationCannotBeApproved() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _submit(applicant);
        _approveSpend(applicant, bond);

        vm.warp(vm.getBlockTimestamp() + WINDOW);

        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_EXPIRED, "the reader says expired without anyone sending a transaction");

        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.NoPendingApplication.selector, ST_EXPIRED
        ));
        app.approveArbiterApplication(applicant);
        assertFalse(reg.isRegisteredArbiter(applicant), "and nobody is seated on a dead application");
    }

    function test_6b_ApplicationLivesUntilTheLastSecond() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _submit(applicant);
        _approveSpend(applicant, bond);

        vm.warp(vm.getBlockTimestamp() + WINDOW - 1);
        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_PENDING, "one second before the end it is still alive");

        app.approveArbiterApplication(applicant);
        assertTrue(reg.isRegisteredArbiter(applicant), "and can still be approved");
    }

    /// The other half of expiry: the address is free to apply again, and the
    /// dead record leaves no wait behind — expiry is not a refusal.
    function test_6c_AfterExpiryTheSameAddressMayApplyAgain() public {
        _submit(applicant);
        vm.warp(vm.getBlockTimestamp() + WINDOW);

        vm.prank(applicant);
        app.applyForArbiterSeat();

        (uint8 state, uint256 submittedAt, , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_PENDING, "the new application stands");
        assertEq(submittedAt, vm.getBlockTimestamp(), "and it is dated now, not seven days ago");
        assertEq(app.getApplicantCount(), 1, "the public list still names him once");
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 7 — a refusal costs seven days
    // ══════════════════════════════════════════════════════════════════════

    function test_7_RefusedApplicantWaitsSevenDaysAndThenMayApply() public {
        _submit(applicant);

        uint256 refusedAt = vm.getBlockTimestamp();
        vm.expectEmit(true, true, false, true, address(diamond));
        emit ArbiterApplicationsFacet.ArbiterApplicationRejected(
            applicant, owner, REFUSAL, refusedAt + WINDOW
        );
        app.rejectArbiterApplication(applicant, REFUSAL);

        (uint8 state, , , uint256 decidedAt, address decidedBy) = app.getArbiterApplication(applicant);
        assertEq(state, ST_REJECTED, "refused");
        assertEq(decidedAt, refusedAt, "at this moment");
        assertEq(decidedBy, owner, "and the refusal has a name on it");

        // One second before the wait is over.
        vm.warp(refusedAt + WINDOW - 1);
        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.RejectedTooRecently.selector, refusedAt + WINDOW
        ));
        app.applyForArbiterSeat();

        // And on the far side of it.
        vm.warp(refusedAt + WINDOW);
        vm.prank(applicant);
        app.applyForArbiterSeat();
        (uint8 again, , , , ) = app.getArbiterApplication(applicant);
        assertEq(again, ST_PENDING, "seven days later the door is open again");
    }

    function test_7b_RefusalWithoutWordsIsNotAllowed() public {
        _submit(applicant);
        vm.expectRevert(ArbiterApplicationsFacet.ReasonRequired.selector);
        app.rejectArbiterApplication(applicant, "");

        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_PENDING, "a wordless refusal decides nothing");
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 8 — withdrawing leaves nothing in the way
    // ══════════════════════════════════════════════════════════════════════

    function test_8_WithdrawalWorksAndLeavesNoWaitBehind() public {
        _submit(applicant);

        vm.expectEmit(true, false, false, false, address(diamond));
        emit ArbiterApplicationsFacet.ArbiterApplicationWithdrawn(applicant);
        vm.prank(applicant);
        app.withdrawArbiterApplication();

        (uint8 state, , , uint256 decidedAt, address decidedBy) = app.getArbiterApplication(applicant);
        assertEq(state, ST_WITHDRAWN, "taken back");
        assertEq(decidedAt, vm.getBlockTimestamp(), "at this moment");
        assertEq(
            decidedBy, address(0),
            "and nobody is recorded as having decided it: he withdrew, he was not refused"
        );

        // Same block, same address, straight back in. A withdrawal is not a
        // refusal, so none of the seven-day wait applies to it.
        vm.prank(applicant);
        app.applyForArbiterSeat();
        (uint8 again, , , , ) = app.getArbiterApplication(applicant);
        assertEq(again, ST_PENDING, "he may apply again immediately");
        assertEq(app.getApplicantCount(), 1, "and the public list still names him exactly once");
    }

    function test_8b_WithdrawalThroughForwarderCreditsTheHuman() public {
        _submit(applicant);
        _forwardFrom(APPLICANT_PK, abi.encodeWithSelector(app.withdrawArbiterApplication.selector));

        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_WITHDRAWN, "the withdrawal belongs to the signer, not the forwarder");
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 9 — the chief decides on the same footing as the owner
    // ══════════════════════════════════════════════════════════════════════

    function test_9a_ChiefApproves() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _setChief(chief);
        _submit(applicant);
        _approveSpend(applicant, bond);

        vm.prank(chief);
        app.approveArbiterApplication(applicant);

        assertTrue(reg.isRegisteredArbiter(applicant), "the chief seated him");
        assertEq(acc.getSeatedBy(applicant), chief, "and the chain says it was the chief");
    }

    function test_9b_ChiefRejects() public {
        _setChief(chief);
        _submit(applicant);

        vm.prank(chief);
        app.rejectArbiterApplication(applicant, REFUSAL);

        (uint8 state, , , , address decidedBy) = app.getArbiterApplication(applicant);
        assertEq(state, ST_REJECTED, "refused by the chief");
        assertEq(decidedBy, chief, "with his name on it");
    }

    function test_9c_StrangerDecidesNothing() public {
        _submit(applicant);

        vm.prank(stranger);
        vm.expectRevert(ArbiterApplicationsFacet.NotOwnerOrChief.selector);
        app.approveArbiterApplication(applicant);

        vm.prank(stranger);
        vm.expectRevert(ArbiterApplicationsFacet.NotOwnerOrChief.selector);
        app.rejectArbiterApplication(applicant, REFUSAL);
    }

    // ══════════════════════════════════════════════════════════════════════
    // SCENE 10 — the ratchet: governance arrives and this door is finished
    // ══════════════════════════════════════════════════════════════════════

    function test_10_AfterTheDaoManualAdmissionIsClosedAndTheAutomaticDoorWorks() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _submit(applicant);
        _approveSpend(applicant, bond);
        assertTrue(app.isManualAdmissionOpen(), "before governance this door is the door");

        _activateDao();
        assertFalse(app.isManualAdmissionOpen(), "and afterwards it is not");

        // Nothing manual works any more, for anybody.
        vm.expectRevert(ArbiterApplicationsFacet.ManualAdmissionClosed.selector);
        app.approveArbiterApplication(applicant);

        vm.expectRevert(ArbiterApplicationsFacet.ManualAdmissionClosed.selector);
        app.rejectArbiterApplication(applicant, REFUSAL);

        address newcomer = address(0x0FF1CE);
        _seedRecord(newcomer, 3_000, 10);
        vm.prank(newcomer);
        vm.expectRevert(ArbiterApplicationsFacet.ManualAdmissionClosed.selector);
        app.applyForArbiterSeat();

        // The successor door is open, and it needs no human decision.
        vm.prank(applicant);
        reg.applyAsArbiter();
        assertTrue(reg.isRegisteredArbiter(applicant), "the automatic door seats him");
    }

    /// The other half of the ratchet, and it is not the same statement: a
    /// person may always clean up his own dead record, even after the door has
    /// gone. Forcing him to leave it standing in a public list would be spite.
    function test_10b_WithdrawalStillWorksAfterTheDao() public {
        _submit(applicant);
        _activateDao();

        vm.prank(applicant);
        app.withdrawArbiterApplication();
        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_WITHDRAWN, "he can still take back his own application");
    }

    // ══════════════════════════════════════════════════════════════════════
    // CIRCUMSTANCES — the five questions this project asks of everything
    // ══════════════════════════════════════════════════════════════════════

    /// Two submissions in a row: the second is refused and the FIRST IS INTACT.
    /// The second half is the one worth checking — a door that refuses but
    /// half-overwrites is worse than one that accepts.
    function test_C1_SecondSubmissionIsRefusedAndTheFirstSurvives() public {
        uint256 t0 = vm.getBlockTimestamp();
        _submit(applicant);

        vm.warp(t0 + 1 days);
        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.ApplicationAlreadyPending.selector, t0
        ));
        app.applyForArbiterSeat();

        (uint8 state, uint256 submittedAt, uint256 expiresAt, , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_PENDING, "the first application still stands");
        assertEq(submittedAt, t0, "still dated when it was filed");
        assertEq(expiresAt, t0 + WINDOW, "and it did not get a fresh week out of the attempt");
        assertEq(app.getApplicantCount(), 1, "and he is named once, not twice");
    }

    /// Approval and withdrawal inside one block, both orders. Nothing here
    /// depends on the clock, so whichever lands first must leave the second
    /// with nothing to do — and must leave the state consistent either way.
    function test_C2a_WithdrawThenApproveInOneBlock() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _submit(applicant);
        _approveSpend(applicant, bond);
        uint256 walletBefore = usdc.balanceOf(applicant);

        vm.prank(applicant);
        app.withdrawArbiterApplication();

        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.NoPendingApplication.selector, ST_WITHDRAWN
        ));
        app.approveArbiterApplication(applicant);

        assertFalse(reg.isRegisteredArbiter(applicant), "he withdrew, so he is not in the corps");
        assertEq(usdc.balanceOf(applicant), walletBefore, "and his money never moved");
        assertEq(acc.getArbiterBond(applicant), 0, "no bond stands against a withdrawn application");
    }

    function test_C2b_ApproveThenWithdrawInOneBlock() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _submit(applicant);
        _approveSpend(applicant, bond);

        app.approveArbiterApplication(applicant);

        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.NoPendingApplication.selector, ST_APPROVED
        ));
        app.withdrawArbiterApplication();

        assertTrue(reg.isRegisteredArbiter(applicant), "he is seated and cannot un-seat himself this way");
        assertEq(acc.getArbiterBond(applicant), bond, "and his bond is where it should be");
    }

    /// A sitting arbiter applying again. Refused by the same error the
    /// automatic door uses, so a caller decodes one selector either way.
    function test_C3_SittingArbiterCannotApply() public {
        reg.addArbiter(applicant);

        vm.prank(applicant);
        vm.expectRevert(ArbiterRegistryFacet.AlreadyArbiter.selector);
        app.applyForArbiterSeat();
    }

    /// Approving something that was never filed. Named, and it names the state
    /// it found: "nobody ever applied" is a different message to send than "it
    /// ran out yesterday".
    function test_C4_ApprovingAnApplicationThatDoesNotExist() public {
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.NoPendingApplication.selector, ST_NONE
        ));
        app.approveArbiterApplication(address(0xDEAD));

        vm.expectRevert(ArbiterApplicationsFacet.ApplicantZeroAddress.selector);
        app.approveArbiterApplication(address(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    // SEAMS — limits that live on the OTHER door and would otherwise have a
    // way round them through this one
    // ══════════════════════════════════════════════════════════════════════

    /// `addArbiter` caps the chief's bloc below the number of votes that
    /// decides an appeal. Without the same cap here, the chief would grow his
    /// bloc through this door at one press per applicant and the cap over there
    /// would be decoration.
    function test_S1_ChiefCannotGrowHisBlocThroughApprovals() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _setChief(chief);

        // First seating: allowed, bloc goes to one.
        _submit(applicant);
        _approveSpend(applicant, bond);
        vm.prank(chief);
        app.approveArbiterApplication(applicant);
        assertEq(reg.getChiefBloc(), 1, "the chief's bloc is one");

        // Second: would reach the deciding majority, so it is refused HERE,
        // with the registry's own error.
        address second = address(0xA202);
        _seedRecord(second, 3_000, 10);
        usdc.mint(second, bond);
        _submit(second);
        _approveSpend(second, bond);

        vm.prank(chief);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterRegistryFacet.ChiefBlocWouldDecideAppeal.selector, uint256(2), uint256(2)
        ));
        app.approveArbiterApplication(second);

        assertFalse(reg.isRegisteredArbiter(second), "the second was not seated");
        assertEq(reg.getChiefBloc(), 1, "and the bloc did not grow");

        // The owner is under no such cap, exactly as in addArbiter: he is the
        // one who decides composition, and capping him would cap his ability to
        // dilute the chief's bloc.
        app.approveArbiterApplication(second);
        assertTrue(reg.isRegisteredArbiter(second), "the owner seats him");
    }

    /// Undoing a removal is the mirror of a removal, and removing is not the
    /// chief's. `addArbiter` says so; this door has to say the same, or the
    /// rule has a second entrance.
    function test_S2_ChiefCannotReseatARemovedArbiterThroughApprovals() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        _setChief(chief);

        // A real removal, through the real doors, so `removedAt` is written by
        // the code that owns it rather than by vm.store.
        reg.addArbiter(applicant);
        acc.proposeRemoval(
            applicant, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the evidence"), REFUSAL
        );
        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());
        acc.removeArbiterForCause(
            applicant, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("the evidence"), address(0), REFUSAL
        );
        assertFalse(reg.isRegisteredArbiter(applicant), "setup: he is out of the corps");

        _submit(applicant);
        _approveSpend(applicant, bond);

        vm.prank(chief);
        vm.expectRevert(ArbiterRegistryFacet.ReseatingRemovedIsOwnerOnly.selector);
        app.approveArbiterApplication(applicant);

        // The owner may, and he pays the ordinary price: the removal window
        // stays on the man, because this door is not a way to buy past it.
        app.approveArbiterApplication(applicant);
        assertTrue(reg.isRegisteredArbiter(applicant), "the owner reseated him");
        assertTrue(
            acc.isSuspended(applicant),
            "and the removal's own suspension window survives the reseating"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE PUBLIC LIST
    // ══════════════════════════════════════════════════════════════════════

    function test_L1_ListNamesEveryApplicantOnceInOrder() public {
        address a = address(0xA1A1);
        address b = address(0xB2B2);
        _seedRecord(a, 3_000, 10);
        _seedRecord(b, 3_000, 10);

        _submit(a);
        _submit(applicant);
        _submit(b);

        address[] memory all = app.getApplicants();
        assertEq(all.length, 3, "three people pushed the door");
        assertEq(all[0], a, "in the order they first did");
        assertEq(all[1], applicant);
        assertEq(all[2], b);
        assertEq(app.getApplicantCount(), 3, "and the count agrees");
    }

    function test_L2_PagingPastTheEndIsEmptyNotARevert() public {
        _submit(applicant);

        address[] memory page = app.getApplicantsPage(0, 10);
        assertEq(page.length, 1, "a window wider than the list returns the list");
        assertEq(page[0], applicant);

        assertEq(app.getApplicantsPage(1, 10).length, 0, "and past the end it returns nothing");
        assertEq(app.getApplicantsPage(0, 0).length, 0, "a zero window returns nothing too");
    }

    // ══════════════════════════════════════════════════════════════════════
    // HELPERS
    // ══════════════════════════════════════════════════════════════════════

    /// Seeds XP and streak straight into ReputationStorage — there is no door
    /// that grants them without playing whole deals, and this file is not about
    /// how XP is earned.
    ///
    /// ⚠️ It reads back through the LIVE getters after writing. The slot
    /// offsets above were taken from the struct, and a struct that gains a
    /// field in the middle would leave this helper writing into a neighbour's
    /// slot in silence — every scene here would then test a candidate with no
    /// record at all, and the ones that expect a refusal would still pass.
    function _seedRecord(address who, uint256 xp, uint256 streak) internal {
        vm.store(address(diamond), keccak256(abi.encode(who, uint256(REP_BASE) + SLOT_XP)), bytes32(xp));
        vm.store(
            address(diamond),
            keccak256(abi.encode(who, uint256(REP_BASE) + SLOT_CLEAN_STREAK)),
            bytes32(streak)
        );
        assertEq(rep.getXP(who), xp, "seeding XP hit the wrong slot");
        assertEq(rep.getCleanStreak(who), streak, "seeding the streak hit the wrong slot");
    }

    function _submit(address who) internal {
        vm.prank(who);
        app.applyForArbiterSeat();
    }

    function _approveSpend(address who, uint256 amount) internal {
        vm.prank(who);
        usdc.approve(address(diamond), amount);
    }

    function _setChief(address who) internal {
        reg.setChiefArbiter(who);
    }

    /// Governance on, through the real doors and in the order the registry
    /// insists on. Three of them since 26 August 2026 (decisions 50 and 51),
    /// and each refuses in its own way if the one before it is skipped:
    ///
    ///   • the corps must be EARNED — `activateDAO()` refuses below
    ///     DAO_THRESHOLD unique active users. Seeded straight into
    ///     ReputationStorage: ten thousand real completions is not a test;
    ///   • the successor is PROPOSED, not appointed;
    ///   • the successor CONFIRMS with a transaction of his own, and only then
    ///     does `daoAddress` stop being zero — which is what `activateDAO()`
    ///     checks.
    function _activateDao() internal {
        vm.store(
            address(diamond),
            bytes32(uint256(REP_BASE) + SLOT_UNIQUE_ACTIVE_USERS),
            bytes32(reg.getDaoThreshold())
        );
        reg.setDAOAddress(daoSuccessor);
        vm.prank(daoSuccessor);
        reg.acceptDAOAddress();
        reg.activateDAO();
        assertTrue(reg.isDaoActive(), "setup: governance is live");
    }

    /// A real signed ERC-2771 request, relayed by a third address that is
    /// neither the signer nor the forwarder — which is what a relayer is.
    function _forwardFrom(uint256 pk, bytes memory data) internal {
        address relayer = address(0x9999);
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  vm.addr(pk),
            to:    address(diamond),
            value: 0,
            gas:   1_000_000,
            nonce: forwarder.getNonce(vm.addr(pk)),
            data:  data
        });

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
                address(forwarder)
            )),
            structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.prank(relayer);
        (bool ok, bytes memory ret) = forwarder.execute(req, abi.encodePacked(r, s, v));
        assertTrue(ok, string.concat("forwarded call failed: ", vm.toString(ret)));
    }

    function _repeat(string memory unit, uint256 times) internal pure returns (string memory out) {
        out = "";
        for (uint256 i = 0; i < times; i++) out = string.concat(out, unit);
    }
}
