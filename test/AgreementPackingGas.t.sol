// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AgreementPackingFixture.sol";

// ============================================================
// 1. GAS
// ============================================================

contract AgreementPackingGasTest is PackingFixture {
    /// The six transactions of a disputed deal, each one priced with the
    /// clone's slots cold — the same shape the audit used, so the two numbers
    /// can be put side by side.
    ///
    /// fund -> activate -> markDone -> raiseDispute -> respondToDispute ->
    /// resolveDispute.
    function testFullLifecycleGas() public {
        Agreement a = _clone(7);
        usdc.mint(CLIENT, AMOUNT);
        vm.prank(CLIENT);
        usdc.approve(address(a), AMOUNT);

        // The arbiter is the diamond itself: setArbiter skips the registry
        // check for that one address, which is what lets this run without a
        // diamond behind it.
        vm.prank(DIAMOND);
        a.setArbiter(DIAMOND);

        uint256 total;
        uint256 g;

        vm.cool(address(a));
        vm.prank(CLIENT);
        g = gasleft();
        a.fund();
        total += g - gasleft();

        vm.cool(address(a));
        vm.prank(EXECUTOR);
        g = gasleft();
        a.activate();
        total += g - gasleft();

        vm.cool(address(a));
        vm.prank(EXECUTOR);
        g = gasleft();
        a.markDone();
        total += g - gasleft();

        vm.cool(address(a));
        vm.prank(CLIENT);
        g = gasleft();
        a.raiseDispute();
        total += g - gasleft();

        vm.cool(address(a));
        vm.prank(EXECUTOR);
        g = gasleft();
        a.respondToDispute();
        total += g - gasleft();

        vm.cool(address(a));
        vm.prank(DIAMOND);
        g = gasleft();
        a.resolveDispute(false);
        total += g - gasleft();

        emit log_named_uint("gas: full deal lifecycle, 6 transactions", total);
    }

    /// The read side. getDetails() is what the deal page and the NFT renderer
    /// ask for, and it touches every field this change moved.
    function testGetDetailsGasOnAColdClone() public {
        Agreement a = _fundedClone(7);
        vm.prank(EXECUTOR);
        a.activate();

        vm.cool(address(a));
        uint256 g = gasleft();
        a.getDetails();
        uint256 used = g - gasleft();

        emit log_named_uint("gas: getDetails() with every slot cold", used);
    }

    /// status() alone, cold. Every screen calls it first and the renderer
    /// calls it twice.
    function testStatusGasOnAColdClone() public {
        Agreement a = _fundedClone(7);
        vm.prank(EXECUTOR);
        a.activate();

        vm.cool(address(a));
        uint256 g = gasleft();
        a.status();
        uint256 used = g - gasleft();

        emit log_named_uint("gas: status() with every slot cold", used);
    }
}


// ============================================================
// 1b. THE AUDIT'S OWN BENCH, REBUILT IN THE REPOSITORY
// ============================================================
//
// The 163_896 -> 40_297 figure in the shape-before-mainnet audit
// was NOT measured on the real Agreement -- it could not have been, since
// fund() alone moves a token and mints two NFTs. It was measured on two model
// contracts with the same semantics and different layouts, in a foundry
// project outside the repository that no longer exists.
//
// So the model is rebuilt here, to the same recipe: the same six writes, the
// slots cooled between them so every write is priced as its own transaction,
// and nothing else in the frame. It answers one question and only one -- is
// the layout difference worth what the audit said it was worth -- and it
// answers it inside the repository, where it can be re-run.
//
// The initialisation write (`deadlineDays`) is outside the measured total in
// both models, because it is outside it in reality too: both layouts pay one
// zero-to-nonzero SSTORE at initialize(), and counting it would only add the
// same 20_000 to both sides.
//
// ⚠️ RUN THIS WITH `forge test --isolate`, or the number is a fiction. Without
// it every call in a test body is one transaction, so the second and later
// SSTOREs to a slot already written in that same transaction cost 100 gas
// under EIP-2200 -- which flatters the packed side enormously, since all six
// of its writes land on ONE slot. `vm.cool` does not fix this: it resets the
// warm/cold access list, not the transaction's record of each slot's original
// value. Measured both ways, 28 August 2026: without --isolate the packed
// model reads 16_617, with it 159_941.
//
// Under --isolate each call also carries the 21_000 intrinsic transaction
// cost, which the audit's figures do not include. Subtract 6 * 21_000 =
// 126_000 from the printed totals to compare with them.

contract LayoutAsShipped {
    uint256 public deadlineDays;      // slot 0
    uint256 public fundedAt;          // slot 1
    uint256 public activatedAt;       // slot 2
    uint256 public markedDoneAt;      // slot 3
    uint256 public disputedAt;        // slot 4
    uint256 public resolvedAt;        // slot 5
    bool    public clientWonDispute;  // slot 6
    bool    public finalized;         // slot 6
    uint8   public finalStatus;       // slot 6
    uint256 private pad1;             // slot 7   (extras)
    uint256 private pad2;             // slot 8   (nextExtraId)
    uint256 private pad3;             // slot 9   (extrasTotal)
    uint256 private pad4;             // slot 10  (pendingExtrasTotal)
    bool    public clientResponded;   // slot 11
    bool    public executorResponded; // slot 11

    function init(uint256 d) external { deadlineDays = d; }
    function fund() external { fundedAt = block.timestamp; }
    function activate() external { activatedAt = block.timestamp; }
    function markDone() external { markedDoneAt = block.timestamp; }
    function raiseDispute() external { disputedAt = block.timestamp; clientResponded = true; }
    function respond() external { executorResponded = true; }
    function resolve(bool won) external {
        resolvedAt = block.timestamp;
        clientWonDispute = won;
        finalized = true;
        finalStatus = 5;
    }
    function readTen() external view returns (uint256 sum) {
        sum = deadlineDays + fundedAt + activatedAt + markedDoneAt + disputedAt + resolvedAt;
        if (clientWonDispute)  sum += 1;
        if (finalized)         sum += 2;
        sum += finalStatus;
        if (clientResponded)   sum += 4;
        if (executorResponded) sum += 8;
    }
}

contract LayoutPacked {
    uint40  private _fundedAt;          // slot 0
    uint40  private _activatedAt;       // slot 0
    uint40  private _markedDoneAt;      // slot 0
    uint40  private _disputedAt;        // slot 0
    uint40  private _resolvedAt;        // slot 0
    bool    private _clientWonDispute;  // slot 0
    bool    private _finalized;         // slot 0
    uint8   private _finalStatus;       // slot 0
    bool    private _clientResponded;   // slot 0
    bool    private _executorResponded; // slot 0
    uint16  private _deadlineDays;      // slot 0  -- 32 of 32 bytes

    function init(uint256 d) external { _deadlineDays = uint16(d); }
    function fund() external { _fundedAt = uint40(block.timestamp); }
    function activate() external { _activatedAt = uint40(block.timestamp); }
    function markDone() external { _markedDoneAt = uint40(block.timestamp); }
    function raiseDispute() external { _disputedAt = uint40(block.timestamp); _clientResponded = true; }
    function respond() external { _executorResponded = true; }
    function resolve(bool won) external {
        _resolvedAt = uint40(block.timestamp);
        _clientWonDispute = won;
        _finalized = true;
        _finalStatus = 5;
    }
    function readTen() external view returns (uint256 sum) {
        sum = uint256(_deadlineDays) + _fundedAt + _activatedAt + _markedDoneAt + _disputedAt + _resolvedAt;
        if (_clientWonDispute)  sum += 1;
        if (_finalized)         sum += 2;
        sum += _finalStatus;
        if (_clientResponded)   sum += 4;
        if (_executorResponded) sum += 8;
    }
}

contract LayoutModelBenchTest is Test {
    function testTheAuditsSixTransactionModel() public {
        LayoutAsShipped shipped = new LayoutAsShipped();
        LayoutPacked    packed  = new LayoutPacked();

        shipped.init(7);
        packed.init(7);

        uint256 a = _lifecycle(address(shipped));
        uint256 b = _lifecycle(address(packed));

        emit log_named_uint("model: 6 transactions, layout as shipped", a);
        emit log_named_uint("model: 6 transactions, packed", b);
        emit log_named_uint("model: difference", a - b);

        assertLt(b, a, "packing did not make the model cheaper");
    }

    function testTheAuditsTenFieldRead() public {
        LayoutAsShipped shipped = new LayoutAsShipped();
        LayoutPacked    packed  = new LayoutPacked();

        shipped.init(7);
        packed.init(7);
        _lifecycle(address(shipped));
        _lifecycle(address(packed));

        vm.cool(address(shipped));
        uint256 g = gasleft();
        shipped.readTen();
        uint256 a = g - gasleft();

        vm.cool(address(packed));
        g = gasleft();
        packed.readTen();
        uint256 b = g - gasleft();

        emit log_named_uint("model: ten-field read, layout as shipped", a);
        emit log_named_uint("model: ten-field read, packed", b);
        emit log_named_uint("model: difference", a - b);

        assertLt(b, a, "packing did not make the read cheaper");
    }

    /// The six transactions, each with the target's slots cold.
    function _lifecycle(address target) private returns (uint256 total) {
        uint256 g;

        vm.cool(target);
        g = gasleft();
        (bool ok,) = target.call(abi.encodeWithSignature("fund()"));
        total += g - gasleft();
        require(ok, "fund");

        vm.cool(target);
        g = gasleft();
        (ok,) = target.call(abi.encodeWithSignature("activate()"));
        total += g - gasleft();
        require(ok, "activate");

        vm.cool(target);
        g = gasleft();
        (ok,) = target.call(abi.encodeWithSignature("markDone()"));
        total += g - gasleft();
        require(ok, "markDone");

        vm.cool(target);
        g = gasleft();
        (ok,) = target.call(abi.encodeWithSignature("raiseDispute()"));
        total += g - gasleft();
        require(ok, "raiseDispute");

        vm.cool(target);
        g = gasleft();
        (ok,) = target.call(abi.encodeWithSignature("respond()"));
        total += g - gasleft();
        require(ok, "respond");

        vm.cool(target);
        g = gasleft();
        (ok,) = target.call(abi.encodeWithSignature("resolve(bool)", true));
        total += g - gasleft();
        require(ok, "resolve");
    }
}
