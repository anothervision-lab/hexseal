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

/// Shared plumbing: an implementation, a deployer and a token. No diamond.
abstract contract PackingFixture is Test {
    Agreement         impl;
    AgreementDeployer cloneDeployer;
    MockUSDCPacking   usdc;

    address constant CLIENT    = address(0xC11E17);
    address constant EXECUTOR  = address(0xE8EC);
    address constant DIAMOND   = address(0xD1A);   // deliberately codeless
    address constant FORWARDER = address(0xF04D);

    uint256 constant AMOUNT = 100_000_000; // $100 USDC

    function setUp() public virtual {
        impl          = new Agreement();
        cloneDeployer = new AgreementDeployer(address(this), address(impl));
        usdc          = new MockUSDCPacking();
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

