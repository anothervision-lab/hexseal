// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Agreement.sol";
import "../src/AgreementDeployer.sol";

// ============================================================
// AgreementPackingFixture.sol — the five deal timestamps, the five flags and the
// deadline share ONE storage slot, and the deal has to behave the same as it
// did when each of them owned thirty-two bytes.
//
// The shape-before-mainnet audit of 26 August 2026, form B.
//
// Three separate jobs live in this file, and they are separate on purpose:
//
//   * AgreementPackingGasTest — the number the change exists for. The six
//     transactions of a full deal, every slot cooled between them so each
//     write is priced as its own transaction, exactly the way the audit
//     measured. Printed, not asserted against a magic constant: the point is
//     to be comparable across the change, and a threshold would only say what
//     somebody once believed.
//
//   * AgreementPackingBoundsTest — every packed field at zero, at the top of
//     its type and one below it, plus the one place the widths have to be
//     argued rather than chosen: `activatedAt + deadlineDays * 1 days +
//     DEADLINE_GRACE` must not overflow when BOTH terms are at their maximum.
//     Form A of the same audit measured what overflow costs there: seven doors
//     shut, the money in the clone, no rescuer.
//
//   * AgreementPackingIndependenceTest — the failure mode packing actually
//     has. A shared slot means a write to one field can clobber another, and
//     no ordinary test notices, because ordinary tests set one field at a
//     time and read it straight back. So: drive every field to a DIFFERENT,
//     recognisable value in one deal, then read all ten and check each one.
//
// The diamond address is left codeless throughout. Every diamond call in
// Agreement is guarded by `_diamondHasCode()`, so a codeless address turns all
// of them off and leaves the storage cost of the deal itself, which is the
// thing under measurement.
// ============================================================

contract MockUSDCPacking {
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

/// ⚠️ THE ONE DIAMOND CALL THAT IS NOT TOLERATED, AND THE ONLY REASON THIS
/// FIXTURE HAS A DIAMOND AT ALL (20 October 2026).
///
/// `Agreement.raiseDispute` takes the dispute fee at the door, through the
/// diamond, and the call is HARD -- no fee, no dispute, because a tolerated
/// charge is not a charge. A codeless diamond therefore does not merely switch
/// that call off the way it switches off the other six; it closes the door.
/// Four scenes here drive `_disputedAt` through the real door because the whole
/// point of this file is that no field is written by a cheat.
///
/// So the fee door gets a stub and nothing else does: this contract answers the
/// two selectors the paid dispute needs and reverts on everything else, which
/// is byte-for-byte what a codeless address did for the tolerated calls -- they
/// sit in `try/catch` and a revert is caught exactly as an absence was.
///
/// ⚠️ WHAT IT COSTS, SAID OUT LOUD: `_diamondHasCode()` now answers TRUE on
/// this rig, so the six tolerated calls are ATTEMPTED and caught instead of
/// skipped. That is gas, and it is why the pinned figures in
/// test/AgreementPackingGas.t.sol moved with this change rather than staying
/// put. The packing itself -- which slot holds what -- is untouched by it.
contract MockDiamondPacking {
    address public immutable usdc;
    mapping(address => uint256) public held;
    mapping(address => address) public payerOf;

    constructor(address usdc_) { usdc = usdc_; }

    function holdDisputeFee(address payer, uint256 amount) external {
        held[msg.sender]    = amount;
        payerOf[msg.sender] = payer;
        require(
            MockUSDCPacking(usdc).transferFrom(payer, address(this), amount),
            "packing stub: the door charge did not move"
        );
    }

    function settleDisputeFee(bool) external {
        uint256 amount = held[msg.sender];
        if (amount == 0) return;
        held[msg.sender] = 0;
        MockUSDCPacking(usdc).transfer(payerOf[msg.sender], amount);
    }
}

/// Shared plumbing: an implementation, a deployer and a token, plus the stub
/// above at the diamond address.
abstract contract PackingFixture is Test {
    Agreement         impl;
    AgreementDeployer cloneDeployer;
    MockUSDCPacking   usdc;

    address constant CLIENT    = address(0xC11E17);
    address constant EXECUTOR  = address(0xE8EC);
    /// ⚠️ NO LONGER CODELESS, 20 OCTOBER 2026 -- see MockDiamondPacking above.
    /// The address is kept so that every clone this fixture makes still names
    /// the same diamond, and the stub is etched onto it in `setUp`.
    address constant DIAMOND   = address(0xD1A);
    address constant FORWARDER = address(0xF04D);

    uint256 constant AMOUNT = 100_000_000; // $100 USDC

    /// The door charge on this fixture's one pot size: 3% of $100 is $3, under
    /// the ten dollar floor, so the floor decides. A hand literal, like every
    /// other figure in this file.
    uint256 constant DOOR_CHARGE = 10_000_000;

    function setUp() public virtual {
        impl          = new Agreement();
        cloneDeployer = new AgreementDeployer(address(this), address(impl));
        usdc          = new MockUSDCPacking();
        // Etched rather than `new`: the clones are made with DIAMOND hard-coded
        // and the addresses this fixture prints are pinned elsewhere.
        MockDiamondPacking stub = new MockDiamondPacking(address(usdc));
        vm.etch(DIAMOND, address(stub).code);
        // `immutable usdc` lives in the stub's CODE, so the etched copy carries
        // the token address with it -- nothing to re-point.
    }

    /// Money and an allowance for the dispute door, for the scenes that open a
    /// dispute. Exactly the charge, so the purse arithmetic stays readable.
    function _armDoorCharge(address who) internal {
        usdc.mint(who, DOOR_CHARGE);
        vm.prank(who); usdc.approve(DIAMOND, DOOR_CHARGE);
    }

    function _clone(uint256 deadlineDays) internal returns (Agreement) {
        return Agreement(
            cloneDeployer.deploy(
                CLIENT, EXECUTOR, address(0),
                AMOUNT, deadlineDays, "Standard work terms",
                DIAMOND, address(usdc), FORWARDER, address(this)
            )
        );
    }

    function _fundedClone(uint256 deadlineDays) internal returns (Agreement a) {
        a = _clone(deadlineDays);
        usdc.mint(CLIENT, AMOUNT);
        vm.startPrank(CLIENT);
        usdc.approve(address(a), AMOUNT);
        a.fund();
        vm.stopPrank();
    }
}

