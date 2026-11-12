// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  THE ROAD INTO THE CORPS, FOR EVERY RIG THAT NEEDS A SEATED ARBITER
// ============================================================
//
// WHY THIS FILE EXISTS. From 8 November 2026 `addArbiter` no longer seats
// anybody: it records an INVITATION, and the invited man answers it himself
// with `acceptArbiterInvitation`, which takes his entry bond and seats him in
// one transaction. Both entrances — the invitation and the self-service
// `applyAsArbiter` — now cost `ArbiterRegistryStorage.ENTRY_BOND`.
//
// There were a hundred and eighty-odd places in test/ whose whole business with
// `addArbiter` was "put a seated arbiter on the bench so that the scene can
// start". The alternative to one helper was a hundred and eighty copies of
// "invite, mint, approve, prank, accept", and a copy that drifted would be the
// copy that seated nobody.
//
// ⚠️ A FREE FUNCTION AND NOT A BASE CLASS, for the reason AppealLotRig.sol is
// one: the scenes that need it sit on at least six different rigs
// (MoneyPathBase, BoardsFixture, DiamondDeathEscrowBase, ArbiterTwoFacetBench,
// Diamond.t.sol's own, the upgrade rehearsals), and a shared base would have to
// be threaded into all six. A file-level function reaches the cheat codes
// through the address forge-std itself derives, and any contract can call it.
//
// ⚠️ IT TAKES NO `vm.prank` WITH IT, AND IT MUST BE CALLED UNPRANKED. The
// invitation is `onlyOwner`, so the press has to come from the rig's owner —
// which is the test contract in every rig here. A pending prank would be eaten
// by the first call below and the invitation would be pressed by the wrong
// address, so a scene that wants to measure WHO may press keeps calling
// `addArbiter` directly instead of coming through here.
//
// ⚠️ THE MONEY IS DELIBERATELY NEUTRAL, and that is the one design decision in
// this file worth arguing. `fundEntryBond` mints EXACTLY one bond and raises
// the allowance by EXACTLY one bond, so after a successful seating the man's
// wallet and his allowance are back where the scene left them: every assertion
// in those hundred and eighty files about what an arbiter holds goes on saying
// the true thing without being rewritten one by one.
//
// ⚠️ AND THAT NEUTRALITY IS EXACTLY WHY IT CANNOT BE USED TO MIGRATE A SCENE
// ABOUT THE PRICE. A scene that asserted "the seat took nothing from him" will
// pass through this helper unchanged and KEEP PASSING while the entrance costs
// ten dollars — the wallet really is where it was, because the helper put the
// bond there. Those scenes are rewritten by hand, by what they mean, and they
// are named one by one in the task report. The diamond's own balance is the
// half that does move, and it moves by `ENTRY_BOND` per seat.
//
// ⚠️ THE BOND TOKEN IS READ OFF THE RIG'S OWN STORAGE rather than taken as an
// argument, so a caller cannot hand in the wrong mock. `FactoryStorage.usdc` is
// field 0 at the namespace base, which is true for a real diamond (initFactory)
// and for the light bench alike (ArbiterTwoFacetBench._seedBenchUsdc writes
// that very slot). A rig with no token under it gets a named refusal here
// instead of a bare `BondTokenNotSet` from three frames down.

import {Vm} from "forge-std/Vm.sol";
import {ArbiterRegistryFacet} from "../src/facets/ArbiterRegistryFacet.sol";
import {ArbiterApplicationsFacet} from "../src/facets/ArbiterApplicationsFacet.sol";
import {IDiamondCut, IDiamondLoupe} from "../src/DiamondProxy.sol";

// The cheat-code address, derived the way forge-std derives it rather than
// pasted as a literal.
Vm constant SEAT_VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

// `FactoryStorage.FACTORY_STORAGE_POSITION`, and `usdc` is its FIRST field.
// The same literal ArbiterTwoFacetBench carries, held against the live layout
// by test/StorageLayout.t.sol.
bytes32 constant SEAT_FACTORY_BASE =
    0x6e1a7c9e564b098cf0d979de1ae0cacf8bfb22a7e8f2c8f4c244a2031b744700;

// ⚠️ TEN DOLLARS, AS A LITERAL FIXED BY A PERSON, and NOT read back out of
// `ArbiterRegistryStorage.ENTRY_BOND`. A rig that asked the contract what its
// own price is would fund the right amount at fifty dollars, at one cent and
// at nought — and every scene standing on it would stay green while the price
// moved. If this number and the contract's disagree, the seating reverts with
// `BondNotApproved` and says both figures out loud.
uint256 constant SEAT_ENTRY_BOND = 10_000_000;

/// The three things any of the mocks under these rigs can do. Deliberately
/// narrow: `mint` because a rig may print money, `approve`/`allowance` because
/// the entry bond is pulled rather than pushed.
interface ISeatBondToken {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// The bond token this rig was configured with.
function entryBondToken(address diamond) view returns (address token) {
    token = address(uint160(uint256(SEAT_VM.load(diamond, SEAT_FACTORY_BASE))));
    require(token != address(0), "seat rig: no bond token under FactoryStorage.usdc on this rig");
}

/// One entry bond, and an allowance just big enough to spend it.
///
/// ⚠️ THE ALLOWANCE IS RAISED AND NEVER SET. A rig that had already approved
/// the diamond for `type(uint256).max` — most of them have, for the per-case
/// bond — is left exactly as it was, which also keeps the sum off the overflow
/// that `allowed + bond` would reach there.
function fundEntryBond(address diamond, address who) {
    address token = entryBondToken(diamond);
    ISeatBondToken(token).mint(who, SEAT_ENTRY_BOND);
    uint256 allowed = ISeatBondToken(token).allowance(who, diamond);
    if (allowed < SEAT_ENTRY_BOND) {
        SEAT_VM.prank(who);
        ISeatBondToken(token).approve(diamond, allowed + SEAT_ENTRY_BOND);
    }
}

/// A token for a rig that never called `initFactory`.
///
/// ⚠️ IT KEEPS BALANCES AND IT CHECKS ALLOWANCES, deliberately. The entry bond
/// is PULLED, and `ArbiterRegistryStorage.takeEntryBond` makes its three named
/// refusals off this contract's own answers — so a mock that said yes to
/// everything would make every seating pass whatever the rig had funded, and
/// `BondNotApproved`/`BondBalanceTooLow` would be unreachable from here.
contract SeatRigEntryBondUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

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
}

/// Puts a bond token under a rig that has none, and leaves one that has alone.
///
/// The same device `ArbiterTwoFacetBench._seedBenchUsdc` uses, and the same
/// slot: `FactoryStorage.usdc` is field 0 at the namespace base. A rig built
/// through `initFactory` already has a token there and is untouched.
function seedEntryBondToken(address diamond) returns (address token) {
    token = address(uint160(uint256(SEAT_VM.load(diamond, SEAT_FACTORY_BASE))));
    if (token != address(0)) return token;

    token = address(new SeatRigEntryBondUSDC());
    SEAT_VM.store(diamond, SEAT_FACTORY_BASE, bytes32(uint256(uint160(token))));
    require(entryBondToken(diamond) == token, "seat rig: the token was seeded into the wrong slot");
}

/// Both halves of "this rig can seat somebody", for the narrow benches that
/// have neither: a bond token and the door the invited man answers through.
///
/// ⚠️ IT DEPLOYS, SO IT MOVES THE CALLER'S NONCE. Call it AFTER the diamond
/// exists — a bench that asserts its own diamond's address (there is one) would
/// otherwise find it moved.
function openTheEntranceOn(address diamond) {
    seedEntryBondToken(diamond);
    mountAcceptDoor(diamond);
}

/// Routes `acceptArbiterInvitation` on a rig that does not already route it.
///
/// ⚠️ WHY THIS IS NEEDED AT ALL, AND WHY IT IS A LINE IN A SETUP RATHER THAN
/// SOMETHING HIDDEN INSIDE `inviteAndSeatArbiter`. About a dozen rigs here
/// never mounted ArbiterApplicationsFacet (they predate it) or mounted a
/// hand-written handful of its selectors, so the door an invited man answers
/// through is routed nowhere and the seating would die in the diamond's
/// fallback. Mounting it is a `diamondCut`, i.e. a transaction of its own that
/// emits its own event, and a cut fired from inside a seating helper would
/// land between a scene's `vm.expectEmit` and the event it was waiting for.
/// So it is called ONCE, in the rig that needs it, next to the rest of its
/// wiring.
///
/// It is a no-op where the door is already there (every rig built through
/// `DeployFull.buildRemainingCuts`), so it is safe to leave in a rig that
/// later gains the full facet. The caller must be the diamond's owner.
function mountAcceptDoor(address diamond) {
    bytes4 sel = ArbiterApplicationsFacet.acceptArbiterInvitation.selector;
    if (IDiamondLoupe(diamond).facetAddress(sel) != address(0)) return;

    bytes4[] memory sels = new bytes4[](1);
    sels[0] = sel;

    IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
    cut[0] = IDiamondCut.FacetCut(
        address(new ArbiterApplicationsFacet()), IDiamondCut.FacetCutAction.Add, sels
    );
    IDiamondCut(diamond).diamondCut(cut, address(0), "");
}

/// Invite, pay, sit — the whole new road in, pressed by the rig's owner.
///
/// ⚠️ NO ASSERTION FOLLOWS, AND NONE IS NEEDED. The seat is written by the
/// answer itself, so there is no path on which this returns with nobody
/// seated: either `acceptArbiterInvitation` succeeds, or it reverts and takes
/// the scene down by name. A `require` on `isRegisteredArbiter` would only add
/// a selector the narrower rigs do not all mount.
function inviteAndSeatArbiter(address diamond, address who) {
    ArbiterRegistryFacet(diamond).addArbiter(who);
    fundEntryBond(diamond, who);
    SEAT_VM.prank(who);
    ArbiterApplicationsFacet(diamond).acceptArbiterInvitation();
}
