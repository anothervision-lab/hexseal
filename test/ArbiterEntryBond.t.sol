// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// TEN DOLLARS AT THE DOOR, THE SAME TEN AT BOTH DOORS, AND SEATING BY HAND
// BECOMES AN INVITATION.
//
// The owner's decision of 8 November 2026. Two things in it, and the second is
// the one that changes a shape rather than a number:
//
//   1. the entrance costs ENTRY_BOND again — the same amount whether a man puts
//      himself forward or the owner asks him in — and it goes home when he lets
//      the seat go;
//   2. `addArbiter` stops seating anybody. It records an INVITATION, and the man
//      answers it himself with a call that takes his bond and seats him in ONE
//      transaction.
//
// The owner's argument for (2), and it is stronger than the one it replaced:
// seat a man by hand and leave him unbonded and he lands in the state "I am
// sitting and I cannot judge", which a SCREEN would then have to explain. An
// invitation does not explain that state — it removes it.
//
// ⚠️ WHAT THIS FILE IS REALLY FOR: THE HALF OF THE SEPTEMBER DECISION THAT MUST
// SURVIVE. The seat bond was retired on 22 September 2026 for a property
// written into `applyAsArbiter` in so many words — "there is no way to end up
// with a payment and no seat". The owner's instruction is that the new bond
// preserve it. A transfer is back in the door, so that property now has to be
// held by the ORDER of the writes, and the order is the opposite of the
// intuitive one:
//
//   * MONEY FIRST, SEAT SECOND is the unsafe order. `transferFrom` hands
//     control to a token the owner configures; inside the callback the man is
//     not yet seated and his invitation is still standing, so a re-entrant
//     token walks back in, pays a second time, seats him, returns — and the
//     outer call seats him AGAIN while recording ONE bond. Twenty dollars
//     paid, ten recorded: the forbidden state, reached by the order that reads
//     as the careful one.
//   * SEAT FIRST, MONEY LAST is what src/ does. The callback meets a seated man
//     and a deleted invitation, the inner call refuses, and a refusal inside
//     `transferFrom` takes the whole transaction down.
//
// Section 4 below is that measurement, and it is the only reason to believe the
// sentence rather than the paragraph.
//
// ⚠️ THE RIG IS A WHOLE DIAMOND, for the reason every arbiter rig here is: the
// bond is written through one facet's storage handle and read through another's,
// and two separately deployed facets have two separate storages at the same
// namespace offset. Three scenes build a SECOND rig of their own, because the
// bond token is fixed by `initFactory` and those scenes need a hostile one.
//
// ⚠️ EVERY EXPECTED NUMBER HERE IS A LITERAL FIXED BY A PERSON, never read back
// out of the thing under test. A scene that asks the contract what its own
// price is and then checks the price against that answer agrees with itself at
// any value.

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
import "../src/facets/ArbiterVaultFacet.sol";
import "../src/facets/TreasuryLinkFacet.sol";
import "../src/facets/ReputationFacet.sol";
import "../src/JobReceiptFacet.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";
import "../script/DeployFull.s.sol";
import {ArbiterAppealFacet} from "../src/facets/ArbiterAppealFacet.sol";

/// The honest token: it verifies the EIP-712 digest, checks the deadline and
/// spends a nonce, exactly as FiatTokenV2 does on Base.
///
/// ⚠️ IT HAS TO BE THE HONEST ONE. Half of what the signature door promises is
/// ENFORCED BY THE TOKEN and not by a line of ours — a paper signed by somebody
/// else, a paper already spent, a paper out of date. Against a mock that sets
/// the allowance and asks nothing (`MockUSDCB` in test/BoardsFixture.sol says so
/// in its own comment) every such scene would pass while proving nothing.
contract EntryBondUSDC {
    string  public constant name     = "USD Coin";
    string  public constant version  = "2";
    uint8   public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    bytes32 public immutable DOMAIN_SEPARATOR;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function permit(
        address tokenOwner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp <= deadline, "EIP2612: permit is expired");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, tokenOwner, spender, value, nonces[tokenOwner], deadline))
            )
        );
        address recovered = ecrecover(digest, v, r, s);
        require(recovered != address(0) && recovered == tokenOwner, "EIP2612: invalid signature");

        nonces[tokenOwner] += 1;
        allowance[tokenOwner][spender] = value;
    }
}

/// A token that answers `false` instead of reverting — the older ERC-20 shape.
/// Real USDC reverts, but the diamond's bond token is set by an owner
/// transaction and not fixed in src/, so a door that ignored the return value
/// would take the seat and leave the money where it was.
contract RefusingEntryBondUSDC is EntryBondUSDC {
    function transferFrom(address, address, uint256) external pure override returns (bool) {
        return false;
    }
}

/// A token that calls BACK INTO THE DIAMOND, as the man himself, before moving
/// anything. The one shape in which the order of the writes is observable from
/// outside.
///
/// ⚠️ IT PRANKS, and that is the point rather than a convenience. Without it
/// the re-entrant call arrives as the TOKEN and `_msgSender()` answers with the
/// token's address, so the diamond sees a stranger with no invitation and the
/// scene would prove nothing about the man's own seat. Cheatcodes are reachable
/// from any contract in a forge run.
contract ReentrantEntryBondUSDC is EntryBondUSDC {
    address public  diamond;
    address public  victim;
    bool    public  reentered;

    function arm(address diamond_, address victim_) external {
        diamond = diamond_;
        victim  = victim_;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (!reentered && diamond != address(0)) {
            reentered = true;
            Vm(address(uint160(uint256(keccak256("hevm cheat code"))))).prank(victim);
            ArbiterApplicationsFacet(diamond).acceptArbiterInvitation();
        }
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ArbiterEntryBondTest is Test {
    DiamondProxy     diamond;
    EntryBondUSDC    usdc;
    MinimalForwarder forwarder;

    ArbiterRegistryFacet     reg;
    ArbiterVaultFacet        vault;
    ArbiterApplicationsFacet apps;
    ArbiterAccountabilityFacet acc;
    ReputationFacet          rep;

    address owner = address(this);

    /// ⚠️ TEN DOLLARS, AS A LITERAL. The owner's number, written here and NOT
    /// read from `ArbiterRegistryStorage.ENTRY_BOND`: a scene whose expected
    /// side comes out of the declaration under test passes at fifty dollars, at
    /// one cent and at nought.
    uint256 constant ENTRY_BOND = 10_000_000;

    /// Seven days, as a literal, for the same reason. The invitation's window is
    /// deliberately the one `APPLICATION_TTL` already owns (the owner's
    /// instruction: no new number about the world), and a scene that read that
    /// constant back would be two readers of one declaration — it would stay
    /// green if the number moved, because both sides would move together.
    uint256 constant INVITATION_WINDOW = 7 days;

    /// Half a year, as a literal. `REMOVAL_COOLDOWN`.
    uint256 constant REMOVAL_COOLDOWN = 180 days;

    /// The run `applyAsArbiter` asks for. The owner fixed this at five.
    uint256 constant STREAK_REQUIRED = 5;

    /// `ArbiterApplicationsFacet`'s bond states, as literals: 0 NONE,
    /// 1 UNPOSTED, 2 SAGGING, 3 WHOLE. The constants are `internal` in the
    /// facet, and that is just as well — section 7 is about a number a CLONE
    /// compares against, and the clone carries its own copy.
    uint8 constant BOND_STATE_NONE     = 0;
    uint8 constant BOND_STATE_UNPOSTED = 1;
    uint8 constant BOND_STATE_SAGGING  = 2;

    /// Namespace bases. `cleanStreak` is ReputationStorage field 9 and
    /// `streakClockStartedAt` is field 14; the numbers are not taken on trust —
    /// `_grantTheStreak` writes and then reads back through the live getter, so
    /// a layout that moves turns the SETUP red instead of quietly seeding
    /// nothing.
    bytes32 constant REP_BASE          = 0xa32193c5e38bd2de27c8550f156d709eafdc63aaa4290e5e27473f2ffc097400;
    bytes32 constant ARB_BASE          = 0xaae71de0594cbcb5434f0ab7f7501c1be178552bf788b418a1c2624ba9718d00;
    uint256 constant SLOT_CLEAN_STREAK = 9;
    uint256 constant SLOT_STREAK_CLOCK = 14;

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    function setUp() public {
        // Before the diamond exists there is no window, no deadline and no
        // claim to jump over, so this is the one safe place for the warp that
        // the sixteen-day streak clock needs.
        vm.warp(17 days + 1);

        usdc      = new EntryBondUSDC();
        forwarder = new MinimalForwarder();
        diamond   = _buildRig(address(usdc), address(forwarder));

        reg   = ArbiterRegistryFacet(address(diamond));
        vault = ArbiterVaultFacet(address(diamond));
        apps  = ArbiterApplicationsFacet(address(diamond));
        acc   = ArbiterAccountabilityFacet(address(diamond));
        rep   = ReputationFacet(address(diamond));
    }

    // ══════════════════════════════════════════════════════════════════════
    //  1. THE INVITATION
    // ══════════════════════════════════════════════════════════════════════

    /// THE HEART OF REQUIREMENT ONE. The owner presses and nobody is sitting.
    ///
    /// Everything else in section 1 is about the edges of the invitation; this
    /// is about the invitation existing at all. A door that still seated on the
    /// press would leave the invited man in the state the owner's decision was
    /// taken to remove — seated, unbonded, unable to judge.
    function test_AnInvitationDoesNotSeatAnybodyByItself() public {
        address invited = address(0xC0FFEE);

        reg.addArbiter(invited);

        assertFalse(vault.isRegisteredArbiter(invited), "the press seated him anyway");
        assertEq(usdc.balanceOf(address(diamond)), 0, "the press moved money");
        assertEq(vault.getArbiters().length, 0, "the roster grew on the press");

        (address inviter, uint256 invitedAt, uint256 expiresAt, bool live) =
            apps.getArbiterInvitation(invited);
        assertEq(inviter,   owner,                             "the record does not name the owner");
        assertEq(invitedAt, vm.getBlockTimestamp(),            "the record carries no clock");
        assertEq(expiresAt, vm.getBlockTimestamp() + INVITATION_WINDOW, "the window is not seven days");
        assertTrue(live, "the offer is not live in the block it was made");

        (uint8 state, uint256 bond, ) = apps.getBondState(invited);
        assertEq(state, BOND_STATE_NONE, "an invited man reads as holding a seat");
        assertEq(bond,  0,               "an invited man reads as holding money");
    }

    /// MUTATION 3's TARGET. Nobody asked him in.
    function test_AStrangerWithNoInvitationCannotTakeASeat() public {
        address stranger = address(0x5A);
        _fund(stranger);

        vm.prank(stranger);
        vm.expectRevert(ArbiterApplicationsFacet.NoSeatInvitation.selector);
        apps.acceptArbiterInvitation();

        assertFalse(vault.isRegisteredArbiter(stranger), "he seated himself without being asked");
        assertEq(usdc.balanceOf(address(diamond)), 0, "money moved on a refused call");
    }

    /// MUTATION 4's TARGET. The offer ran out, and the refusal says when.
    function test_AnInvitationOlderThanItsWindowIsRefused() public {
        address invited = address(0xC0FFEE);
        _fund(invited);

        reg.addArbiter(invited);
        uint256 expiresAt = vm.getBlockTimestamp() + INVITATION_WINDOW;

        vm.warp(expiresAt);

        vm.prank(invited);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.SeatInvitationExpired.selector, expiresAt, expiresAt
        ));
        apps.acceptArbiterInvitation();

        assertFalse(vault.isRegisteredArbiter(invited), "a dead offer still seated him");
        assertEq(usdc.balanceOf(address(diamond)), 0, "a dead offer still took his money");

        ( , , , bool live) = apps.getArbiterInvitation(invited);
        assertFalse(live, "the form still calls the offer live");
    }

    /// The other side of the same boundary, and it is here so that the scene
    /// above cannot pass by the door being shut altogether.
    function test_AnInvitationOneSecondYoungerThanItsWindowIsStillGood() public {
        address invited = address(0xC0FFEE);
        _fund(invited);

        reg.addArbiter(invited);
        uint256 expiresAt = vm.getBlockTimestamp() + INVITATION_WINDOW;

        vm.warp(expiresAt - 1);

        vm.prank(invited);
        apps.acceptArbiterInvitation();

        assertTrue(vault.isRegisteredArbiter(invited), "one second early was treated as too late");
    }

    /// KEPT BY THE OWNER'S WORD OF 8 NOVEMBER 2026, and recorded as his
    /// decision in src/ rather than flagged as an executor's addition: the
    /// owner may take an unanswered offer back. Without it a mistyped address
    /// stands for seven days with nothing anybody can do about it.
    function test_TheOwnerCanWithdrawAnInvitationBeforeItIsAnswered() public {
        address invited = address(0xC0FFEE);
        _fund(invited);

        reg.addArbiter(invited);
        // ⚠️ `apps` AND NOT `reg`, SINCE THE EVENING OF 8 NOVEMBER 2026. Both
        // handles are the same diamond address, so the call lands in the same
        // place either way; what the type says is WHICH FACET COMPILES the
        // door, and `revokeArbiterInvitation` compiles on
        // ArbiterApplicationsFacet now. Using the wrong handle would not change
        // the transaction, so this line is bookkeeping rather than behaviour --
        // what holds the move itself is the pre-flight census in the cut rigs.
        apps.revokeArbiterInvitation(invited);

        (address inviter, , , bool live) = apps.getArbiterInvitation(invited);
        assertEq(inviter, address(0), "the record outlived its withdrawal");
        assertFalse(live, "the withdrawn offer is still live");

        vm.prank(invited);
        vm.expectRevert(ArbiterApplicationsFacet.NoSeatInvitation.selector);
        apps.acceptArbiterInvitation();

        // And a withdrawal of nothing is refused by name rather than silently
        // succeeding, so an owner who presses twice is told so.
        vm.expectRevert(ArbiterApplicationsFacet.NoSeatInvitation.selector);
        apps.revokeArbiterInvitation(invited);
    }

    /// ⚠️ THE SEAM THIS SCENE OWNS, AND UNTIL 8 NOVEMBER 2026 IT BELONGED
    /// TO NOBODY. The docstring over `revokeArbiterInvitation` promises in so
    /// many words that the door refuses a man who is ALREADY SEATED, and that
    /// the refusal is BY OMISSION rather than by a check — there is no line in
    /// that door asking whether he sits. It refuses him only because answering
    /// an invitation DELETES the record (`ArbiterRegistryStorage.seatOnInvitation`,
    /// one `delete` on its second line), so a seated man has no invitation left
    /// to withdraw and meets `NoSeatInvitation`: the name of a man nobody ever
    /// asked in.
    ///
    /// That makes the promise a property of TWO doors, with the half enforcing
    /// it living inside the other one. Let the answer keep the record some day
    /// — for history, for an appeal panel, for a screen that wants to show who
    /// vouched — and this door quietly starts saying YES against sitting
    /// arbiters: no accusation, no 48-hour pause, no right of reply, and the
    /// bond's fate unstated. Nothing else in the file would notice, because
    /// every other assertion about this door drives an UNANSWERED offer.
    ///
    /// The refusal is asserted BY ITS NAME and not as a bare revert: an unnamed
    /// expectation is satisfied by the owner check as well, and by anything
    /// else that might later revert in there for an unrelated reason. And the
    /// seat is asserted SEPARATELY — the door must not merely fail, it must
    /// leave the man sitting, with his provenance and his ten dollars where
    /// they were.
    function test_TheWithdrawalDoorRefusesAManWhoIsAlreadySeated() public {
        address invited = address(0xC0FFEE);
        _seatByInvitation(invited);

        // The press is the OWNER's (`owner` is this contract), so the owner
        // check is passed and `NoSeatInvitation` is the only refusal that can
        // be reached — which is what makes the name worth asserting.
        vm.expectRevert(ArbiterApplicationsFacet.NoSeatInvitation.selector);
        apps.revokeArbiterInvitation(invited);

        assertTrue(vault.isRegisteredArbiter(invited), "the withdrawal door unseated a sitting arbiter");
        assertEq(vault.getArbiters().length, 1, "the roster lost a sitting arbiter");
        assertEq(acc.getSeatedBy(invited), owner, "the refused press wiped his provenance");

        ( , uint256 bond, ) = apps.getBondState(invited);
        assertEq(bond, ENTRY_BOND, "the refused press touched his bond record");
        assertEq(usdc.balanceOf(address(diamond)), ENTRY_BOND, "the refused press moved money");
    }

    /// THE SEAM THE SPLIT CREATED. `addArbiter` has always died at the
    /// handover; the ANSWER to it is a second door, and a second door is a
    /// second predicate that can drift. An invitation pressed the day before a
    /// handover must not seat a man the day after it.
    function test_TheHandoverShutsTheInvitationAndItsAnswerTogether() public {
        address invited = address(0xC0FFEE);
        _fund(invited);

        reg.addArbiter(invited);

        _handOverSeating();

        vm.prank(invited);
        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        apps.acceptArbiterInvitation();

        // The door it answers is shut by the same predicate, which is the half
        // that was already true and is asserted so that the two cannot drift
        // apart in one direction only.
        vm.expectRevert(ArbiterRegistryFacet.SeatingHandedOver.selector);
        reg.addArbiter(address(0xBEEF));

        assertFalse(vault.isRegisteredArbiter(invited), "he sat down after the handover");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  2. THE MONEY, AT BOTH DOORS
    // ══════════════════════════════════════════════════════════════════════

    /// MUTATION 2's TARGET. Answering the invitation costs ten dollars, and the
    /// money and the seat arrive in the same call.
    function test_AcceptingAnInvitationTakesTheEntryBondFromTheInvitedMan() public {
        address invited = address(0xC0FFEE);
        _fund(invited);
        uint256 before = usdc.balanceOf(invited);

        reg.addArbiter(invited);
        vm.prank(invited);
        apps.acceptArbiterInvitation();

        assertTrue(vault.isRegisteredArbiter(invited), "the answer did not seat him");
        assertEq(usdc.balanceOf(address(diamond)), ENTRY_BOND, "the diamond did not take the bond");
        assertEq(before - usdc.balanceOf(invited), ENTRY_BOND, "the bond did not leave HIS wallet");

        ( , uint256 bond, ) = apps.getBondState(invited);
        assertEq(bond, ENTRY_BOND, "the seat carries no record of the money");

        // The offer is spent, not merely used: a second answer finds nothing.
        (address inviter, , , bool live) = apps.getArbiterInvitation(invited);
        assertEq(inviter, address(0), "the answered offer is still standing");
        assertFalse(live, "the answered offer is still live");

        // And the provenance names the OWNER, not the man who sent the
        // transaction — the field `revokeUnprovenSeat` and the panel audit read.
        assertEq(acc.getSeatedBy(invited), owner, "the invited man reads as self-seated");
    }

    /// MUTATION 2's TARGET, from the other side: no money, no seat. Both
    /// refusals are named, because "you have not approved the diamond" and "you
    /// have spent your USDC" are two different sentences to show a person.
    function test_AnInvitedManWithoutTheMoneyIsRefusedTheSeat() public {
        address broke = address(0xB40CE);
        reg.addArbiter(broke);

        // No allowance at all.
        vm.prank(broke);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.BondNotApproved.selector, 0, ENTRY_BOND
        ));
        apps.acceptArbiterInvitation();
        assertFalse(vault.isRegisteredArbiter(broke), "he sat down without approving anything");

        // An allowance, and an empty wallet behind it.
        vm.prank(broke);
        usdc.approve(address(diamond), ENTRY_BOND);
        vm.prank(broke);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.BondBalanceTooLow.selector, 0, ENTRY_BOND
        ));
        apps.acceptArbiterInvitation();
        assertFalse(vault.isRegisteredArbiter(broke), "he sat down with an empty wallet");

        // The offer survives both refusals — a man who could not pay today has
        // not used anything up.
        ( , , , bool live) = apps.getArbiterInvitation(broke);
        assertTrue(live, "a refusal spent the offer");
    }

    /// MUTATION 1's TARGET. The self-service door charges the same ten dollars.
    function test_SelfEnrolmentTakesTheEntryBondFromTheCandidate() public {
        address candidate = address(0xCA11D1);
        _grantTheStreak(candidate);
        _fund(candidate);
        uint256 before = usdc.balanceOf(candidate);

        vm.prank(candidate);
        reg.applyAsArbiter();

        assertTrue(vault.isRegisteredArbiter(candidate), "the earned door did not seat him");
        assertEq(usdc.balanceOf(address(diamond)), ENTRY_BOND, "the diamond did not take the bond");
        assertEq(before - usdc.balanceOf(candidate), ENTRY_BOND, "the bond did not leave HIS wallet");

        ( , uint256 bond, ) = apps.getBondState(candidate);
        assertEq(bond, ENTRY_BOND, "the seat carries no record of the money");

        // He walked in himself, so nobody vouched for him. The appeal panel
        // reads this field and a self-seated newcomer must not look vouched-for.
        assertEq(acc.getSeatedBy(candidate), address(0), "somebody was recorded as having vouched");
    }

    /// MUTATION 1's TARGET, from the other side.
    function test_SelfEnrolmentIsRefusedWithoutTheMoney() public {
        address candidate = address(0xCA11D2);
        _grantTheStreak(candidate);

        vm.prank(candidate);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.BondNotApproved.selector, 0, ENTRY_BOND
        ));
        reg.applyAsArbiter();

        assertFalse(vault.isRegisteredArbiter(candidate), "a qualified man sat down for free");
        assertEq(usdc.balanceOf(address(diamond)), 0, "money moved on a refused call");
    }

    /// THE OWNER'S RULE IN ONE LINE: the conditions are the same at both doors.
    /// Measured against each other rather than against the constant, so a
    /// change that moved one price and not the other goes red here even if both
    /// scenes above were edited to agree with it.
    function test_BothDoorsChargeTheSameTenDollars() public {
        address byHand = address(0x0A1);
        address earned = address(0x0A2);

        reg.addArbiter(byHand);
        _fund(byHand);
        vm.prank(byHand);
        apps.acceptArbiterInvitation();
        uint256 takenByInvitation = usdc.balanceOf(address(diamond));

        _grantTheStreak(earned);
        _fund(earned);
        vm.prank(earned);
        reg.applyAsArbiter();
        uint256 takenBySelfEnrolment = usdc.balanceOf(address(diamond)) - takenByInvitation;

        assertEq(takenByInvitation,   ENTRY_BOND, "the invitation door charges something else");
        assertEq(takenBySelfEnrolment, ENTRY_BOND, "the earned door charges something else");
        assertEq(takenByInvitation, takenBySelfEnrolment, "the two doors charge different prices");
    }

    /// The form stopped lying. `getApplicationRequirements().bond` has read a
    /// hard zero since 22 September 2026; from 8 November that zero is a lie,
    /// and a screen that prints it tells a man the entrance is free.
    function test_TheRequirementsFormStopsLyingAboutTheBond() public view {
        ( , , uint256 bond, uint256 window) = apps.getApplicationRequirements();
        assertEq(bond,   ENTRY_BOND,        "the form still publishes a price nobody charges");
        assertEq(window, INVITATION_WINDOW, "the form's window is not the invitation's window");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  3. THE BOND GOES HOME
    // ══════════════════════════════════════════════════════════════════════

    /// MUTATION 5's TARGET. He lets the seat go and gets his ten dollars back —
    /// the owner's condition, stated in the same breath as the price.
    function test_ResigningReturnsTheEntryBondInFull() public {
        address seated = _seatByInvitation(address(0xC0FFEE));
        uint256 beforeResign = usdc.balanceOf(seated);

        vm.prank(seated);
        reg.resignAsArbiter();

        assertFalse(vault.isRegisteredArbiter(seated), "he is still in the corps");
        assertEq(usdc.balanceOf(seated) - beforeResign, ENTRY_BOND, "the bond did not come home");
        assertEq(usdc.balanceOf(address(diamond)), 0, "the diamond kept the bond");

        ( , uint256 bond, ) = apps.getBondState(seated);
        assertEq(bond, 0, "the record still says he has money on the table");
    }

    /// MUTATION 5's TARGET, through the log rather than the balance.
    /// `ArbiterResigned`'s second field was a HARD ZERO from 22 September 2026
    /// — a literal in the emit, not a variable — so a feed reading it would
    /// print "returned: 0" over a real refund.
    function test_ArbiterResignedCarriesTheRealNumberAndNotAZero() public {
        address seated = _seatByInvitation(address(0xC0FFEE));

        vm.expectEmit(true, false, false, true, address(diamond));
        emit ArbiterRegistryFacet.ArbiterResigned(seated, ENTRY_BOND);

        vm.prank(seated);
        reg.resignAsArbiter();
    }

    /// THE ROAD BACK, and it is not hypothetical: the four arbiters on Base
    /// Sepolia today hold a zero bond, and the way they reach the new rule is
    /// to walk out and be invited back in.
    ///
    /// So a voluntary exit must leave NO mark that stands in the way. It writes
    /// neither `lastRemovalAt` nor `removedAt`, `clearSeat` erases the
    /// provenance and any proposal, and nothing touches the clean streak. He can
    /// be invited in the next block and answer in the one after.
    function test_AManWhoJustResignedCanBeInvitedBackAndSitDownAgain() public {
        address seated = _seatByInvitation(address(0xC0FFEE));

        vm.prank(seated);
        reg.resignAsArbiter();

        // Nothing permanent was written against him.
        ( , , , , , , , , , uint256 removedAt, , uint256 count, uint256 lastAt, , , ) =
            acc.getArbiterStanding(seated);
        assertEq(removedAt, 0, "resigning wrote the erasable removal mark");
        assertEq(count,     0, "resigning counted as a removal");
        assertEq(lastAt,    0, "resigning wrote the permanent removal moment");

        // And the road back works in the same block.
        reg.addArbiter(seated);
        vm.prank(seated);
        apps.acceptArbiterInvitation();

        assertTrue(vault.isRegisteredArbiter(seated), "a man who resigned cannot be asked back");
        ( , uint256 bond, ) = apps.getBondState(seated);
        assertEq(bond, ENTRY_BOND, "he came back without paying the entrance again");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  4. THE ORDER — THE PROPERTY THE SEPTEMBER DECISION LEFT BEHIND
    // ══════════════════════════════════════════════════════════════════════

    /// MUTATION 6's TARGET, the first half. The pull is HARD: a token that
    /// answers `false` instead of reverting must not buy a seat.
    ///
    /// ⚠️ A SEPARATE RIG, because the bond token is fixed by `initFactory` and
    /// this scene needs a hostile one.
    function test_ATokenThatRefusesTheTransferLeavesNoSeatBehind() public {
        RefusingEntryBondUSDC bad = new RefusingEntryBondUSDC();
        DiamondProxy rig = _buildRig(address(bad), address(forwarder));

        address invited = address(0xC0FFEE);
        bad.mint(invited, ENTRY_BOND * 10);
        vm.prank(invited);
        bad.approve(address(rig), type(uint256).max);

        ArbiterRegistryFacet(address(rig)).addArbiter(invited);

        vm.prank(invited);
        vm.expectRevert(ArbiterApplicationsFacet.BondTransferFailed.selector);
        ArbiterApplicationsFacet(address(rig)).acceptArbiterInvitation();

        assertFalse(
            ArbiterVaultFacet(address(rig)).isRegisteredArbiter(invited),
            "a seat was handed out against a transfer that never happened"
        );
        assertEq(bad.balanceOf(address(rig)), 0, "the diamond thinks it was paid");
    }

    /// MUTATION 6's TARGET, and the whole reason the order in src/ is the
    /// unintuitive one.
    ///
    /// The token calls back into the diamond, as the man himself, before moving
    /// anything. With the seat written FIRST the inner call meets a seated man
    /// and a deleted offer, refuses, and takes the whole transaction down. With
    /// the money taken first it would find the offer still standing, pay a
    /// second ten dollars, seat him, return — and the outer call would seat him
    /// AGAIN, hand out a second roster index and record ONE bond. Twenty
    /// dollars paid, ten refundable.
    ///
    /// ⚠️ `vm.expectRevert()` WITHOUT A SELECTOR, deliberately. Which of the
    /// three guards the inner call meets first is not this scene's subject, and
    /// pinning it would make the scene brittle about something it does not
    /// claim. What it claims is "the second answer does not go through", and the
    /// three assertions after the call are what carry it.
    function test_AReentrantBondTokenCannotBuyTwoSeatsForOneInvitation() public {
        ReentrantEntryBondUSDC evil = new ReentrantEntryBondUSDC();
        DiamondProxy rig = _buildRig(address(evil), address(forwarder));

        address invited = address(0xC0FFEE);
        evil.mint(invited, ENTRY_BOND * 10);
        vm.prank(invited);
        evil.approve(address(rig), type(uint256).max);
        evil.arm(address(rig), invited);

        ArbiterRegistryFacet(address(rig)).addArbiter(invited);

        vm.prank(invited);
        vm.expectRevert();
        ArbiterApplicationsFacet(address(rig)).acceptArbiterInvitation();

        assertFalse(
            ArbiterVaultFacet(address(rig)).isRegisteredArbiter(invited),
            "the re-entrant answer seated him"
        );
        assertEq(evil.balanceOf(address(rig)), 0, "money was taken for a seat nobody got");
        assertEq(
            ArbiterVaultFacet(address(rig)).getArbiters().length, 0,
            "the roster grew for a transaction that reverted"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //  5. THE COOLDOWN EXEMPTION — THE THING THE SPLIT COULD LOSE SILENTLY
    // ══════════════════════════════════════════════════════════════════════

    /// MUTATION 7's TARGET, and the reason this scene exists at all.
    ///
    /// `addArbiter` has always been exempt from the half-year cooldown, because
    /// the owner reverses HIS OWN removal with one press and a cooldown binding
    /// him would turn a mistaken removal into a sentence nobody can lift. When
    /// one door becomes two, an exemption like that disappears without a single
    /// test going red — put `requireCooldownPassed` into the ANSWER and an
    /// invited man removed last month hits six months of silence, while every
    /// other scene in this tree stays green, because nothing else in the tree
    /// ever invited a removed arbiter.
    ///
    /// So the exemption lives with the INVITATION, and this is the lock on it.
    function test_AnInvitedManInsideHisRemovalCooldownStillTakesTheSeat() public {
        address removed = _removeForCause(address(0xDEAD01));

        ( , , , , , , , , , , , , uint256 lastRemovalAt, , , ) = acc.getArbiterStanding(removed);
        assertGt(lastRemovalAt, 0, "setup: the removal wrote no permanent moment, so there is no cooldown to clear");

        // Well inside the half-year: a month after the removal.
        vm.warp(lastRemovalAt + 30 days);
        assertLt(vm.getBlockTimestamp(), lastRemovalAt + REMOVAL_COOLDOWN, "setup: the cooldown has already run out");

        reg.addArbiter(removed);
        _fund(removed);
        vm.prank(removed);
        apps.acceptArbiterInvitation();

        assertTrue(
            vault.isRegisteredArbiter(removed),
            "the owner's invitation now runs into the half-year cooldown"
        );
        // And the suspension the removal imposed is lifted on the way in —
        // otherwise he comes back mute and the invitation is a trap.
        assertFalse(acc.isSuspended(removed), "he came back suspended");
    }

    /// THE NON-ZERO CONTROL FOR THE SCENE ABOVE. A cooldown that refused
    /// nobody would make that test pass for the wrong reason, and "nothing
    /// refused him" and "the rule is switched off" look identical from outside.
    /// So: the same man, the same month, the door he opens HIMSELF.
    function test_TheSelfServiceDoorStillAsksTheCooldown() public {
        address removed = _removeForCause(address(0xDEAD02));

        ( , , , , , , , , , , , , uint256 lastRemovalAt, , , ) = acc.getArbiterStanding(removed);
        vm.warp(lastRemovalAt + 30 days);

        _grantTheStreak(removed);
        _fund(removed);

        vm.prank(removed);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterRegistryStorage.RemovalCooldownActive.selector, lastRemovalAt + REMOVAL_COOLDOWN
        ));
        reg.applyAsArbiter();
    }

    // ══════════════════════════════════════════════════════════════════════
    //  6. BOTH DOORS REACH A MAN WITH NO ETH
    // ══════════════════════════════════════════════════════════════════════

    /// ⚠️ THE SCENE A DIRECT CALL CANNOT PROVE. A test that calls the facet
    /// from the man's own address proves nothing about the relayed path: there
    /// `msg.sender` is the MinimalForwarder and the man's address is in the last
    /// twenty bytes of the calldata. `fundDispute` read `msg.sender` for a month
    /// while every direct-call test stayed green and the paid arbiter call never
    /// once worked (fix d172064, 31 July 2026).
    ///
    /// Both halves of the beggar's problem are in this one scene: he holds ZERO
    /// WEI, so he cannot send the transaction, AND he has granted no allowance,
    /// so an `approve` would need the ETH he does not have. The relayer carries
    /// the call; the signature carries the allowance.
    function test_AnInvitedManWithNoEthAnswersThroughTheForwarderOnAPermit() public {
        uint256 pk = 0xA11CE;
        address invited = vm.addr(pk);

        usdc.mint(invited, ENTRY_BOND);
        reg.addArbiter(invited);

        vm.deal(invited, 0);
        assertEq(invited.balance, 0, "setup: he can afford his own gas");
        assertEq(usdc.allowance(invited, address(diamond)), 0, "setup: he has already approved the diamond");

        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, address(diamond), ENTRY_BOND, deadline);

        _forwardFrom(pk, abi.encodeWithSelector(
            ArbiterApplicationsFacet.acceptArbiterInvitationWithPermit.selector, deadline, v, r, s
        ));

        assertTrue(vault.isRegisteredArbiter(invited), "the relayed answer did not seat him");
        assertFalse(
            vault.isRegisteredArbiter(address(forwarder)),
            "the FORWARDER got the seat: _msgSender() is reading msg.sender"
        );
        assertEq(usdc.balanceOf(address(diamond)), ENTRY_BOND, "the bond was not taken");
        assertEq(usdc.balanceOf(invited), 0, "the bond did not leave HIS wallet");
        // Nothing is left standing: the paper granted exactly the bond and the
        // door spent exactly the bond.
        assertEq(usdc.allowance(invited, address(diamond)), 0, "the diamond kept a claim on his wallet");
        assertEq(acc.getSeatedBy(invited), owner, "the relayed seat reads as self-seated");
    }

    /// The same, at the earned door.
    function test_ACandidateWithNoEthSelfEnrolsThroughTheForwarderOnAPermit() public {
        uint256 pk = 0xB0B;
        address candidate = vm.addr(pk);

        _grantTheStreak(candidate);
        usdc.mint(candidate, ENTRY_BOND);

        vm.deal(candidate, 0);
        assertEq(candidate.balance, 0, "setup: he can afford his own gas");

        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, address(diamond), ENTRY_BOND, deadline);

        _forwardFrom(pk, abi.encodeWithSelector(
            ArbiterApplicationsFacet.applyAsArbiterWithPermit.selector, deadline, v, r, s
        ));

        assertTrue(vault.isRegisteredArbiter(candidate), "the relayed call did not seat him");
        assertEq(usdc.balanceOf(address(diamond)), ENTRY_BOND, "the bond was not taken");
        assertEq(acc.getSeatedBy(candidate), address(0), "a self-enrolled man reads as vouched-for");
    }

    /// An expired paper is refused BY NAME, not by USDC's own string about a
    /// contract the person has never heard of.
    function test_AnExpiredPaperIsRefusedByName() public {
        uint256 pk = 0xA11CE;
        address invited = vm.addr(pk);

        usdc.mint(invited, ENTRY_BOND);
        reg.addArbiter(invited);

        uint256 deadline = vm.getBlockTimestamp() - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(pk, address(diamond), ENTRY_BOND, deadline);

        vm.prank(invited);
        vm.expectRevert(abi.encodeWithSelector(
            ArbiterApplicationsFacet.BondPermitExpired.selector, deadline, vm.getBlockTimestamp()
        ));
        apps.acceptArbiterInvitationWithPermit(deadline, v, r, s);

        assertFalse(vault.isRegisteredArbiter(invited), "a dead paper bought a seat");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  7. WHAT A NON-ZERO BOND MUST NOT SWITCH BACK ON
    // ══════════════════════════════════════════════════════════════════════

    /// ⚠️ THE MOST EXPENSIVE LINE THIS WORK COULD HAVE WRITTEN, and it is not
    /// in src/ — it is the line somebody will add next.
    ///
    /// `getBondState` returns `(state, bond, toPost)`. Every live Agreement
    /// clone staticcalls it and refuses the man as a PARTY when
    /// `state >= BOND_STATE_SAGGING` (2). A clone is nailed to its
    /// implementation for life, so no upgrade reaches it. Since 8 November the
    /// second field is non-zero again, and the obvious tidy-up — "report WHOLE
    /// when the money is there" — would switch rule B back on across every deal
    /// that already exists, silently, with no cut and no line of src/ to point
    /// at. Rule B in its wide form ("an arbiter may never be a party") is
    /// exactly what the owner removed on 22 September 2026, because it cost a
    /// man his living.
    ///
    /// So: the money is reported, the RULE is not.
    function test_ANonZeroEntryBondDoesNotTurnRuleBBackOnForTheClones() public {
        address seated = _seatByInvitation(address(0xC0FFEE));

        (uint8 state, uint256 bond, uint256 toPost) = apps.getBondState(seated);

        assertEq(bond, ENTRY_BOND, "setup: the bond is zero, so this scene proves nothing");
        assertEq(state, BOND_STATE_UNPOSTED, "the clones have started refusing arbiters as parties again");
        assertLt(state, BOND_STATE_SAGGING,  "the clones have started refusing arbiters as parties again");
        assertEq(toPost, 0, "a seat is reported as owing money, and no seat can owe money");

        // And `isArbiterActive` stays the seat alone: with the money taken in
        // the same call, a second question would be the same question.
        assertTrue(apps.isArbiterActive(seated), "a paid-up arbiter reads as unable to act");
    }

    // ══════════════════════════════════════════════════════════════════════
    //  PLUMBING
    // ══════════════════════════════════════════════════════════════════════

    /// A whole diamond around one bond token. Factored out of `setUp` because
    /// the token is fixed by `initFactory`, and three scenes need a hostile one.
    function _buildRig(address token, address fwd) internal returns (DiamondProxy rig) {
        DeployFull deploy = new DeployFull();

        rig = new DiamondProxy(
            owner,
            deploy.buildInitCuts(
                address(new DiamondCutFacet()), address(new DiamondLoupeFacet()),
                address(new OwnershipFacet()), address(new RegistryFacet()), address(new FactoryFacet())
            ),
            address(0), ""
        );
        IDiamondCut(address(rig)).diamondCut(
            deploy.buildRemainingCuts(
                address(new JobBoardFacet()), address(new ServiceBoardFacet()),
                address(new ArbiterRegistryFacet()), address(new ArbiterVaultFacet()),
                address(new ArbiterAccountabilityFacet()), address(new ArbiterApplicationsFacet()),
                address(new TreasuryLinkFacet()), address(new JobReceiptFacet()), address(new ReputationFacet()),
                address(new ArbiterAppealFacet())
            ),
            address(0), ""
        );
        RegistryFacet(address(rig)).initRegistry(address(rig));
        FactoryFacet(address(rig)).initFactory(
            token, address(0xFEE), fwd, address(rig),
            address(new AgreementDeployer(address(rig), address(new Agreement())))
        );
    }

    /// Money and an allowance, on the main rig.
    function _fund(address who) internal {
        usdc.mint(who, ENTRY_BOND * 10);
        vm.prank(who);
        usdc.approve(address(diamond), type(uint256).max);
    }

    /// Invite, pay, sit — the whole new road in, on the main rig.
    function _seatByInvitation(address who) internal returns (address) {
        reg.addArbiter(who);
        _fund(who);
        vm.prank(who);
        apps.acceptArbiterInvitation();
        assertTrue(vault.isRegisteredArbiter(who), "rig: the invitation road does not seat anybody");
        return who;
    }

    /// The streak and the clock under it, written straight into storage and
    /// READ BACK through the live getter, so a layout that moves turns the rig
    /// red instead of quietly seeding nothing.
    function _grantTheStreak(address who) internal {
        vm.store(
            address(diamond),
            keccak256(abi.encode(who, uint256(REP_BASE) + SLOT_STREAK_CLOCK)),
            bytes32(uint256(1))
        );
        vm.store(
            address(diamond),
            keccak256(abi.encode(who, uint256(REP_BASE) + SLOT_CLEAN_STREAK)),
            bytes32(STREAK_REQUIRED)
        );
        assertEq(rep.getCleanStreak(who), STREAK_REQUIRED, "rig: the streak was seeded into the wrong slot");
    }

    /// A real removal for cause, through the real doors, so `lastRemovalAt` is
    /// written by the code that owns it and not by a `vm.store` into a slot
    /// somebody counted by hand.
    function _removeForCause(address who) internal returns (address) {
        _seatByInvitation(who);

        acc.proposeRemoval(
            who, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        vm.warp(vm.getBlockTimestamp() + acc.getRemovalDelay());
        acc.removeArbiterForCause(
            who, ArbiterAccountabilityFacet.Cause.Collusion, keccak256("evidence"), address(0),
            "three times took the disputes of one counterparty and three times ruled in their favour"
        );
        assertFalse(vault.isRegisteredArbiter(who), "rig: he is still in the corps");
        return who;
    }

    /// Governance live AND a successor named — the two-part predicate that
    /// shuts seating by hand. The manual flag is seeded and READ BACK, the
    /// successor goes in through its own real doors.
    function _handOverSeating() internal {
        address dao = address(0xDA0);
        reg.setDAOAddress(dao);
        vm.prank(dao);
        reg.acceptDAOAddress();

        vm.store(
            address(diamond),
            bytes32(uint256(ARB_BASE) + 5),
            bytes32(uint256(uint160(address(0xDA0))) | (uint256(1) << 160))
        );
        require(reg.isDaoActive(), "rig: the manual DAO flag was seeded into the wrong slot");
        require(vault.getDAOAddress() == dao, "rig: the successor was not recorded");
    }

    /// An EIP-2612 paper. The nonce is read off the token rather than counted
    /// here, so a scene that spends one does not have to remember that it did.
    function _signPermit(uint256 pk, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address signer = vm.addr(pk);
        bytes32 structHash = keccak256(
            abi.encode(usdc.PERMIT_TYPEHASH(), signer, spender, value, usdc.nonces(signer), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    /// A real signed ERC-2771 request, relayed by a third address that is
    /// neither the signer nor the forwarder — which is what a relayer is.
    function _forwardFrom(uint256 pk, bytes memory data) internal {
        address relayer = address(0x9999);
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  vm.addr(pk),
            to:    address(diamond),
            value: 0,
            gas:   2_000_000,
            nonce: forwarder.getNonce(vm.addr(pk)),
            deadline: type(uint48).max,   // not this file's subject; the window is locked in ForwardRequestDeadline.t.sol
            data:  data
        });

        bytes32 structHash = keccak256(abi.encode(
            FWD_TYPEHASH, req.from, req.to, req.value, req.gas, req.nonce, req.deadline, keccak256(req.data)
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
}
