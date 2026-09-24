// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// What is left of the arbiter applications mechanism, and what replaced it.
//
// It existed because the automatic door could not open at the start:
// `applyAsArbiter` refused `DAONotActive` on its first line, so before
// governance nobody could put himself forward by any means. On 22 September
// 2026 the owner removed that line — the self-service door is open and asks a
// run of five clean deals — and removed the application door with it, on the
// argument that it asked exactly the same thing and added only one person's
// right to refuse somebody the rules already admit.
//
// So three selectors are gone from this facet and are measured here as gone:
//
//     applyForArbiterSeat()                    0x6fb78a56
//     approveArbiterApplication(address)       0xbcd90be1
//     rejectArbiterApplication(address,string) 0x8e7e21be
//
// ⚠️ FORTY-ODD SCENES WENT WITH THEM, and that is the change rather than a
// loss of coverage: every one of them measured a door that no longer exists.
// What is measured below is what survived — the withdrawal, the filter that
// takes back an unproven seat, the ratchet, the two retired bond doors and the
// reads — plus the two things the removal itself has to be held to: that the
// three selectors are not mounted, and that the entrance which replaced them
// works with governance asleep.
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
import "../src/facets/TreasuryLinkFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";
import "../script/DeployFull.s.sol";
import {ArbiterVaultFacet} from "../src/facets/ArbiterVaultFacet.sol";
import {HandoverReadinessSeed} from "./HandoverReadinessSeed.sol";

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

contract ArbiterApplicationsTest is Test, HandoverReadinessSeed {
    DiamondProxy diamond;
    DeployFull   deploy;
    MockUSDCApplications usdc;
    MinimalForwarder forwarder;

    ArbiterApplicationsFacet   app;
    ArbiterRegistryFacet       reg;
    ArbiterVaultFacet       regVault;
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

    /// Namespace base of ArbiterRegistryStorage, as the library declares it.
    /// Used only by `_seedPendingApplication`, which finds the field inside it
    /// by measurement rather than by counting declarations.
    bytes32 constant ARB_BASE = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;

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
            address(new ArbiterVaultFacet()),
            address(new ArbiterAccountabilityFacet()),
            address(new ArbiterApplicationsFacet()),
            address(new TreasuryLinkFacet()),
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
        regVault = ArbiterVaultFacet(address(diamond));
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
    ///
    /// ⚠️ NO GOVERNANCE IS SWITCHED ON FOR THIS SCENE ANY MORE. Until
    /// 22 September 2026 it had to be: `applyAsArbiter` refused `DAONotActive`
    /// before it ever looked at the streak, so the refusal could not be reached.
    function test_MinCleanStreakMirrorMatchesRegistryRefusal() public {
        (, uint256 minStreak, , ) = app.getApplicationRequirements();

        address candidate = address(0xC0FFEE);
        _seedRecord(candidate, 3_000, minStreak - 1);

        vm.prank(candidate);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterRegistryFacet.InsufficientCleanStreak.selector, minStreak - 1, minStreak
        ));
        reg.applyAsArbiter();
    }

    /// The bond a seat costs, and the oracle is the money. The number this
    /// facet publishes is zero since the per-case cut; a successful
    /// `applyAsArbiter` has to move exactly that much and no more.
    ///
    /// ⚠️ THE APPLICANT IS LEFT SOLVENT AND WITH AN OPEN ALLOWANCE, on purpose.
    /// A scene where the money could not have moved anyway proves nothing about
    /// whether the door tried to move it.
    function test_TheBondMirrorIsZeroAndTheRegistryTakesNothing() public {
        (, , uint256 bond, ) = app.getApplicationRequirements();
        assertEq(bond, 0, "this facet still advertises a price for a seat");

        _approveSpend(applicant, type(uint256).max);
        uint256 walletBefore   = usdc.balanceOf(applicant);
        uint256 diamondBefore  = usdc.balanceOf(address(diamond));

        vm.prank(applicant);
        reg.applyAsArbiter();

        assertTrue(regVault.isRegisteredArbiter(applicant), "the door did not seat him");
        assertEq(usdc.balanceOf(applicant), walletBefore, "the seat took money from him");
        assertEq(usdc.balanceOf(address(diamond)), diamondBefore, "the diamond took money for a seat");
        assertEq(acc.getArbiterBond(applicant), 0, "a bond was booked that nobody paid");
    }

    /// The four numbers a form reads before a man signs anything.
    function test_TheCorpsAsksForFiveCleanDealsAndNoExperience() public view {
        (uint256 minXP, uint256 minStreak, uint256 bond, uint256 window) =
            app.getApplicationRequirements();
        assertEq(minXP,     0,      "experience opens nothing since 20 September 2026");
        assertEq(minStreak, 5,      "the owner fixed the run of clean deals at five");
        assertEq(bond,      0,      "a seat is free since 22 September 2026");
        assertEq(window,    WINDOW, "the window a form counts down");
    }

    /// The words cap is asked of the facet that owns it rather than copied. The
    /// door that still asks for words is `revokeUnprovenSeat`; until
    /// 22 September 2026 `rejectArbiterApplication` asked too, and this scene
    /// measured it there.
    function test_RefusalWordsUseTheSameCapAsTheRemovalDoors() public {
        uint256 cap = acc.getMaxReasonBytes();
        reg.addArbiter(applicant);

        string memory tooLong = _repeat("x", cap + 1);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.ReasonTooLong.selector, cap + 1
        ));
        app.revokeUnprovenSeat(applicant, tooLong);

        vm.expectRevert(ArbiterApplicationsFacet.ReasonRequired.selector);
        app.revokeUnprovenSeat(applicant, "");

        // Exactly the cap goes through, so the refusals above are about the
        // length and not about the door.
        app.revokeUnprovenSeat(applicant, _repeat("x", cap));
        assertFalse(regVault.isRegisteredArbiter(applicant), "the seat was not taken back");
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE DOOR THAT WAS REMOVED (22 September 2026)
    // ══════════════════════════════════════════════════════════════════════

    /// ⚠️ THE EXPECTED SIDE HERE IS A LITERAL SELECTOR, hand-computed with
    /// `cast sig` and written down, NOT derived from the facet under test — the
    /// functions do not exist any more, so there is nothing on the facet to
    /// derive it from, and that is exactly the property being measured.
    ///
    ///     applyForArbiterSeat()                    0x6fb78a56
    ///     approveArbiterApplication(address)       0xbcd90be1
    ///     rejectArbiterApplication(address,string) 0x8e7e21be
    ///
    /// The diamond in this rig is cut by `DeployFull`'s own builders, so this
    /// goes red the moment any of the three is put back into that list.
    ///
    /// ⚠️ WHAT IT DOES NOT SAY: that the three are off the LIVE diamond. They
    /// are not — they are mounted on 0x760F0736... until a cut takes them off
    /// with `Remove`, and that cut is a separate piece of work. This measures
    /// what a fresh deployment carries.
    function test_TheThreeApplicationDoorsAreNotMounted() public {
        bytes4[3] memory gone = [bytes4(0x6fb78a56), bytes4(0xbcd90be1), bytes4(0x8e7e21be)];
        for (uint256 i = 0; i < gone.length; i++) {
            (bool ok, ) = address(diamond).call(abi.encodeWithSelector(gone[i], address(0), ""));
            assertFalse(ok, "a removed application door still answers");
        }

        // And the door that replaced all three does answer, so the loop above is
        // not passing because the whole diamond is deaf.
        _seedRecord(applicant, 0, 5);
        vm.prank(applicant);
        reg.applyAsArbiter();
        assertTrue(regVault.isRegisteredArbiter(applicant), "the entrance that stayed does not work");
    }

    // ══════════════════════════════════════════════════════════════════════
    // WITHDRAWAL — the applicant's own door out, and all that is left of the
    // application mechanism
    // ══════════════════════════════════════════════════════════════════════

    /// ⚠️ THE PENDING RECORD IS WRITTEN INTO STORAGE, and there is no other way
    /// to get one any more: the door that filed applications was removed on
    /// 22 September 2026, so every record this door can ever meet is one filed
    /// BEFORE that — which is the situation being played here.
    ///
    /// The seed is not trusted: `_seedPendingApplication` finds the field by
    /// writing and reading back through the live getter and refuses rather than
    /// guess, so a layout that moves turns the SETUP red instead of quietly
    /// seeding nothing.
    function test_APreExistingApplicationCanStillBeWithdrawn() public {
        _seedPendingApplication(applicant);
        (uint8 before_, , , , ) = app.getArbiterApplication(applicant);
        assertEq(before_, ST_PENDING, "setup: the record is not standing");

        vm.prank(applicant);
        app.withdrawArbiterApplication();

        (uint8 state, , , , address decidedBy) = app.getArbiterApplication(applicant);
        assertEq(state, ST_WITHDRAWN, "the record was not taken back");
        assertEq(decidedBy, address(0), "his own withdrawal was recorded as a decision about him");
    }

    /// The same door through a real forwarder, signed by the applicant and sent
    /// by a third address. This is the scene that holds `_msgSender()` in this
    /// facet: corrupt that body to `msg.sender` and the withdrawal lands on the
    /// forwarder instead of the man.
    function test_WithdrawalThroughTheForwarderCreditsTheHuman() public {
        _seedPendingApplication(applicant);

        _forwardFrom(APPLICANT_PK, abi.encodeWithSelector(app.withdrawArbiterApplication.selector));

        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_WITHDRAWN, "the withdrawal belongs to the signer, not the forwarder");
        (uint8 fwdState, , , , ) = app.getArbiterApplication(address(forwarder));
        assertEq(fwdState, ST_NONE, "the forwarder's own record was written");
    }

    /// Nothing standing, nothing to take back — and the refusal carries the
    /// state that IS there, because "never applied" and "took it back an hour
    /// ago" are two different things to show a person.
    function test_WithdrawingNothingIsRefusedByName() public {
        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.NoPendingApplication.selector, ST_NONE
        ));
        app.withdrawArbiterApplication();
    }

    /// An expired record is not a standing one, and the refusal says so rather
    /// than saying "none".
    function test_AnExpiredApplicationReadsAsExpiredAndCannotBeWithdrawn() public {
        _seedPendingApplication(applicant);
        vm.warp(vm.getBlockTimestamp() + WINDOW);

        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_EXPIRED, "the clock was not folded into the read");

        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.NoPendingApplication.selector, ST_EXPIRED
        ));
        app.withdrawArbiterApplication();
    }

    /// ⚠️ DELIBERATELY NOT GATED ON THE RATCHET. Forcing a person to leave his
    /// own dead record in a public list to prove a point would be spite.
    function test_WithdrawalStillWorksAfterTheDao() public {
        _seedPendingApplication(applicant);
        _activateDao();
        assertFalse(app.isManualAdmissionOpen(), "setup: the ratchet did not turn");

        vm.prank(applicant);
        app.withdrawArbiterApplication();
        (uint8 state, , , , ) = app.getArbiterApplication(applicant);
        assertEq(state, ST_WITHDRAWN, "the ratchet swallowed a withdrawal");
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE RATCHET — what is left of it, and the door it still shuts
    // ══════════════════════════════════════════════════════════════════════

    /// `isManualAdmissionOpen()` is one read that answers "is the hand still in
    /// this at all". It now governs exactly one door: `revokeUnprovenSeat`.
    function test_TheRatchetShutsTheFilterDoorAndNothingElse() public {
        assertTrue(app.isManualAdmissionOpen(), "setup: the hand is already out");
        reg.addArbiter(applicant);

        _activateDao();
        assertFalse(app.isManualAdmissionOpen(), "the ratchet did not turn");

        vm.expectRevert(ArbiterApplicationsFacet.ManualAdmissionClosed.selector);
        app.revokeUnprovenSeat(applicant, REFUSAL);

        // And the automatic entrance is unaffected by the ratchet in either
        // direction — it never was the thing the ratchet governed.
        address candidate = address(0xC0FFEE);
        _seedRecord(candidate, 0, 5);
        vm.prank(candidate);
        reg.applyAsArbiter();
        assertTrue(regVault.isRegisteredArbiter(candidate), "the ratchet shut the automatic door");
    }

    /// Seating by hand dies at the HANDOVER, which is a different predicate from
    /// the one above: `isDaoActive() && daoAddress != 0`. Both hold here, so the
    /// scene shows the door shut; the two are kept apart in the source because
    /// they part company while a successor is unnamed.
    function test_SeatingByHandDiesAtTheHandover() public {
        _activateDao();
        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        reg.addArbiter(address(0xC0FFEE));
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE RETIRED BOND DOORS AND THE READS
    // ══════════════════════════════════════════════════════════════════════

    /// Both bond doors answer by name rather than by a bare failure. They are
    /// kept mounted for exactly that: a removed selector answers a pressed
    /// button with nothing a screen can read out.
    function test_TheRetiredBondDoorsAnswerByName() public {
        vm.prank(applicant);
        vm.expectRevert(ArbiterApplicationsFacet.SeatBondRetired.selector);
        app.postArbiterBond();

        vm.prank(applicant);
        vm.expectRevert(ArbiterApplicationsFacet.SeatBondRetired.selector);
        app.postArbiterBondWithPermit(vm.getBlockTimestamp() + 1 hours, 27, bytes32(0), bytes32(0));
    }

    /// `getBondState` answers NONE or UNPOSTED and nothing else, because nothing
    /// writes a seat bond any more. It stays mounted because every live
    /// Agreement clone calls this selector and a clone is pinned to its
    /// implementation for life.
    function test_GetBondStateAnswersOnlyNoneOrUnposted() public {
        (uint8 none, , ) = app.getBondState(stranger);
        assertEq(none, 0, "a stranger is not NONE");

        reg.addArbiter(applicant);
        (uint8 seated, uint256 bond, ) = app.getBondState(applicant);
        assertEq(seated, 1, "a seat does not read as UNPOSTED");
        assertEq(bond,   0, "a seat carries a bond after all");

        assertTrue(app.isArbiterActive(applicant), "a free seat is not allowed to act");
    }

    /// The public list, and the paged read over it. Nothing can be pushed into
    /// it any more — the door that did was removed — so what these hold is that
    /// the reads survive an empty list rather than reverting on it.
    function test_TheApplicantListReadsEmptyAndPagesWithoutReverting() public view {
        assertEq(app.getApplicantCount(), 0, "somebody is in a list nothing can write to");
        assertEq(app.getApplicants().length, 0, "the list is not empty");
        assertEq(app.getApplicantsPage(0, 10).length, 0, "paging an empty list is not empty");
        assertEq(app.getApplicantsPage(5, 10).length, 0, "paging past the end should be empty, not a revert");
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

    /// A STANDING APPLICATION, WRITTEN STRAIGHT INTO STORAGE, because no door
    /// files one any more. Every record `withdrawArbiterApplication` can ever
    /// meet is one filed before 22 September 2026, and this is that record.
    ///
    /// ⚠️ THE FIELD IS FOUND, NOT COUNTED. Counting the declarations of
    /// `ArbiterRegistryStorage.Data` gives the wrong slot whenever two
    /// neighbours pack into one — `address chiefArbiter` and `bool
    /// daoActiveManual` do exactly that, and a hand-counted offset has already
    /// been measured wrong once in this repository. So each offset is tried,
    /// the live getter is asked where the write landed, and every slot touched
    /// on the way is put back.
    ///
    /// The struct packs `state` (uint8), `submittedAt` and `decidedAt` (uint64
    /// each) into its first slot and `decidedBy` into the second, so one word
    /// is enough to make a record stand.
    function _seedPendingApplication(address who) internal {
        uint64 ts = uint64(vm.getBlockTimestamp());
        bytes32 packed = bytes32(uint256(ST_PENDING) | (uint256(ts) << 8));

        for (uint256 f = 0; f < 64; f++) {
            bytes32 slot = keccak256(abi.encode(who, uint256(ARB_BASE) + f));
            bytes32 old = vm.load(address(diamond), slot);
            vm.store(address(diamond), slot, packed);
            (uint8 state, uint256 submittedAt, , , ) = app.getArbiterApplication(who);
            if (state == ST_PENDING && submittedAt == ts) return;
            vm.store(address(diamond), slot, old);
        }
        revert("rig: arbiterApplications not found - the storage layout moved");
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
        _seedHandoverLiveness(address(diamond));
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
