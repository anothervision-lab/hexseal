// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  DIAMOND-DEATH ESCROW LOCK  —  sections 1-13
// ============================================================
//
// The fixture, the mocks and the kill switches live in
// test/DiamondDeathEscrowBase.sol; the whole argument this file makes is in
// the header of that file. Sections 14-17 (the gas caps and their floors) are
// in test/DiamondDeathGasCaps.t.sol.

import "./DiamondDeathEscrowBase.sol";

contract DiamondDeathEscrowTest is DiamondDeathEscrowBase {
    // ============================================================
    //  1. THE EXTCODESIZE FINDING  (mode C is not mode A/B)
    // ============================================================
    //
    // This is the load-bearing fact for every NO_CODE row below, and it is
    // measured on a standalone probe so the conclusion does not depend on
    // Agreement's own code.

    function testTryCatchDoesNotCatchExtcodesizeGuard() public {
        address dead = address(0xDEAD01);
        assertEq(dead.code.length, 0, "probe target must have no code");
        ExtcodesizeProbe p = new ExtcodesizeProbe(dead);

        // A protected call (try/catch, no return data expected) does NOT
        // reach its catch block. The extcodesize guard solc emits reverts in
        // the caller's frame, outside the protected region.
        (bool ok, ) = address(p).call(abi.encodeWithSignature("protectedNoReturn()"));
        assertFalse(ok, "try/catch is expected NOT to survive a codeless target");

        // A bare call expecting return data reverts too, but for a different
        // reason: solc skips extcodesize when return data is expected, the
        // CALL succeeds with empty returndata, and the ABI decoder reverts.
        (bool ok2, ) = address(p).staticcall(abi.encodeWithSignature("bareWithReturn()"));
        assertFalse(ok2, "bare call with return value must revert on codeless target");

        // And the low-level shape used by Agreement.setArbiter succeeds with
        // empty data — so `if (!ok || ...)` never sees a failure; the revert
        // comes later, out of abi.decode.
        (bool okStatic, uint256 len) = p.lowLevelStatic();
        assertTrue(okStatic, "low-level staticcall to codeless address returns success");
        assertEq(len, 0, "...with empty return data");
    }

    // ============================================================
    //  2. BASELINE — the diamond calls really are live
    // ============================================================
    //
    // Anti-mirror guard. If this fails, every "money still got out" result
    // below is worthless, because the call that was supposedly killed was
    // never working in the first place.

    function testBaselineDiamondCallsAreLive() public {
        _assertDiamondReallyDeaf(Kill.ALIVE);

        Agreement a = _markedDone();
        vm.recordLogs();
        vm.prank(client);
        a.release();

        assertEq(_registryStatus(a), 1, "registry must move to COMPLETED while alive");
        assertFalse(_registrySyncFailedFired(), "RegistrySyncFailed must not fire while alive");
        assertGt(ReputationFacet(address(diamond)).getXP(executor), 0, "autoAwardXP must land while alive");
        assertEq(usdc.balanceOf(executor), DEAL, "executor paid in full");
    }

    // ============================================================
    //  3. release()  — client approves
    // ============================================================

    function _runRelease(Kill mode) internal returns (bool ok) {
        Agreement a = _markedDone();
        _kill(mode);
        _assertDiamondReallyDeaf(mode);

        Snap memory before = _snap(a);
        ok = _callAs(client, a, "release()");

        if (ok) {
            assertEq(usdc.balanceOf(executor) - before.executorBal, DEAL, "executor must receive DEAL");
            assertEq(usdc.balanceOf(address(a)), 0, "escrow must be empty");
        } else {
            assertEq(usdc.balanceOf(address(a)), before.escrowBal, "escrow untouched on revert");
        }
    }

    function testRelease_SelectorsRemoved_MoneyOut() public {
        assertTrue(_runRelease(Kill.SELECTORS_REMOVED), "release must survive a removed selector");
    }

    function testRelease_FacetReverts_MoneyOut() public {
        assertTrue(_runRelease(Kill.FACET_REVERTS), "release must survive a reverting facet");
    }

    function testRelease_NoCode_MoneyOut() public {
        assertTrue(_runRelease(Kill.NO_CODE), "release must survive a codeless diamond");
    }

    // ============================================================
    //  4. triggerAutoApprove()  — the "everybody is silent" path
    // ============================================================

    function _runAutoApprove(Kill mode) internal returns (bool ok) {
        Agreement a = _markedDone();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);
        _kill(mode);
        _assertDiamondReallyDeaf(mode);

        Snap memory before = _snap(a);
        ok = _callAs(stranger, a, "triggerAutoApprove()");

        if (ok) {
            assertEq(usdc.balanceOf(executor) - before.executorBal, DEAL, "executor must receive DEAL");
            assertEq(usdc.balanceOf(address(a)), 0, "escrow must be empty");
        } else {
            assertEq(usdc.balanceOf(address(a)), before.escrowBal, "escrow untouched on revert");
        }
    }

    function testAutoApprove_SelectorsRemoved_MoneyOut() public {
        assertTrue(_runAutoApprove(Kill.SELECTORS_REMOVED), "auto-approve must survive a removed selector");
    }

    function testAutoApprove_FacetReverts_MoneyOut() public {
        assertTrue(_runAutoApprove(Kill.FACET_REVERTS), "auto-approve must survive a reverting facet");
    }

    function testAutoApprove_NoCode_MoneyOut() public {
        assertTrue(_runAutoApprove(Kill.NO_CODE), "auto-approve must survive a codeless diamond");
    }

    // ============================================================
    //  5. triggerActivationTimeout()  — executor never showed up
    // ============================================================

    function _runActivationTimeout(Kill mode) internal returns (bool ok) {
        Agreement a = _createFundedAgreement();
        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);
        _kill(mode);
        _assertDiamondReallyDeaf(mode);

        Snap memory before = _snap(a);
        ok = _callAs(client, a, "triggerActivationTimeout()");

        if (ok) {
            assertEq(usdc.balanceOf(client) - before.clientBal, DEAL, "client must be refunded DEAL");
            assertEq(usdc.balanceOf(address(a)), 0, "escrow must be empty");
        } else {
            assertEq(usdc.balanceOf(address(a)), before.escrowBal, "escrow untouched on revert");
        }
    }

    function testActivationTimeout_SelectorsRemoved_MoneyOut() public {
        assertTrue(_runActivationTimeout(Kill.SELECTORS_REMOVED), "refund must survive a removed selector");
    }

    function testActivationTimeout_FacetReverts_MoneyOut() public {
        assertTrue(_runActivationTimeout(Kill.FACET_REVERTS), "refund must survive a reverting facet");
    }

    function testActivationTimeout_NoCode_MoneyOut() public {
        assertTrue(_runActivationTimeout(Kill.NO_CODE), "refund must survive a codeless diamond");
    }

    // ============================================================
    //  6. triggerDeadlineTimeout()  — work never delivered
    // ============================================================

    function _runDeadlineTimeout(Kill mode) internal returns (bool ok) {
        Agreement a = _activated();
        vm.warp(block.timestamp + DEADLINE_DAYS * 1 days + DEADLINE_GRACE + 1);
        _kill(mode);
        _assertDiamondReallyDeaf(mode);

        Snap memory before = _snap(a);
        ok = _callAs(client, a, "triggerDeadlineTimeout()");

        if (ok) {
            assertEq(usdc.balanceOf(client) - before.clientBal, DEAL, "client must be refunded DEAL");
            assertEq(usdc.balanceOf(address(a)), 0, "escrow must be empty");
        } else {
            assertEq(usdc.balanceOf(address(a)), before.escrowBal, "escrow untouched on revert");
        }
    }

    function testDeadlineTimeout_SelectorsRemoved_MoneyOut() public {
        assertTrue(_runDeadlineTimeout(Kill.SELECTORS_REMOVED), "refund must survive a removed selector");
    }

    function testDeadlineTimeout_FacetReverts_MoneyOut() public {
        assertTrue(_runDeadlineTimeout(Kill.FACET_REVERTS), "refund must survive a reverting facet");
    }

    function testDeadlineTimeout_NoCode_MoneyOut() public {
        assertTrue(_runDeadlineTimeout(Kill.NO_CODE), "refund must survive a codeless diamond");
    }

    // ============================================================
    //  7. rejectExtra()  — the only money path that never calls the diamond
    // ============================================================

    function _runRejectExtra(Kill mode) internal returns (bool ok) {
        Agreement a = _activated();
        // The top-up fee is read off the diamond, so it is quoted while the
        // diamond is still alive -- which is also the only time a top-up can
        // be proposed at all. rejectExtra itself never asks the diamond
        // anything, and the point of this scene is that it still works after
        // the diamond is gone.
        uint256 extraFee = a.quoteExtraFee(EXTRA);
        usdc.mint(client, EXTRA + extraFee);
        vm.startPrank(client);
        usdc.approve(address(a), EXTRA + extraFee);
        a.proposeExtra(EXTRA, "extra terms");
        vm.stopPrank();

        _kill(mode);
        _assertDiamondReallyDeaf(mode);

        Snap memory before = _snap(a);
        vm.prank(executor);
        (ok, ) = address(a).call(abi.encodeWithSignature("rejectExtra(uint256)", uint256(0)));

        if (ok) {
            assertEq(
                usdc.balanceOf(client) - before.clientBal,
                EXTRA + extraFee,
                "client must get the extra back, held fee with it"
            );
        }
    }

    function testRejectExtra_SelectorsRemoved_MoneyOut() public {
        assertTrue(_runRejectExtra(Kill.SELECTORS_REMOVED), "rejectExtra never touches the diamond");
    }

    function testRejectExtra_FacetReverts_MoneyOut() public {
        assertTrue(_runRejectExtra(Kill.FACET_REVERTS), "rejectExtra never touches the diamond");
    }

    function testRejectExtra_NoCode_MoneyOut() public {
        assertTrue(_runRejectExtra(Kill.NO_CODE), "rejectExtra never touches the diamond");
    }

    // ============================================================
    //  8. triggerArbiterTimeout() — THE ESCAPE HATCH
    // ============================================================
    //
    // The only exit from a disputed deal, and the guard in front of it runs
    // BEFORE any money moves. It used to be a bare
    // `IArbiterRegistryFacet(diamond).hasSubmittedVerdict(...)`, which made an
    // unreachable diamond mean "a verdict exists" and stranded the pot for
    // ever. It now reads through Agreement._verdictInFlight: a gas-capped
    // low-level staticcall whose failure means "no verdict", so the money
    // leaves in all three modes. Section 13 holds the other half of that
    // bargain — a LIVE diamond still blocks the hatch.

    function _runArbiterTimeoutUnclaimed(Kill mode) internal returns (bool ok) {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        _kill(mode);
        _assertDiamondReallyDeaf(mode);

        Snap memory before = _snap(a);
        ok = _callAs(client, a, "triggerArbiterTimeout()");

        if (ok) {
            // both sides showed up -> pot split in half
            assertEq(usdc.balanceOf(client)   - before.clientBal,   DEAL_HALF, "client half");
            assertEq(usdc.balanceOf(executor) - before.executorBal, DEAL_HALF, "executor half");
            assertEq(usdc.balanceOf(address(a)), 0, "escrow must be empty");
        } else {
            assertEq(usdc.balanceOf(address(a)), before.escrowBal, "escrow untouched on revert");
        }
    }

    function testArbiterTimeoutUnclaimed_Alive_MoneyOut() public {
        assertTrue(_runArbiterTimeoutUnclaimed(Kill.ALIVE), "baseline: the escape hatch works while alive");
    }

    function testArbiterTimeoutUnclaimed_SelectorsRemoved_MoneyOut() public {
        assertTrue(
            _runArbiterTimeoutUnclaimed(Kill.SELECTORS_REMOVED),
            "the only escape must survive a removed selector"
        );
    }

    function testArbiterTimeoutUnclaimed_FacetReverts_MoneyOut() public {
        assertTrue(
            _runArbiterTimeoutUnclaimed(Kill.FACET_REVERTS),
            "the only escape must survive a reverting facet"
        );
    }

    function testArbiterTimeoutUnclaimed_NoCode_MoneyOut() public {
        assertTrue(
            _runArbiterTimeoutUnclaimed(Kill.NO_CODE),
            "the only escape must survive a codeless diamond"
        );
    }

    /// Same hatch, but an arbiter did claim the dispute (Agreement.arbiter is
    /// the diamond itself). Claiming needs a live diamond, so the kill lands
    /// after the claim.
    function _runArbiterTimeoutClaimed(Kill mode) internal returns (bool ok) {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        _claimByArbiter(a);

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        _kill(mode);
        _assertDiamondReallyDeaf(mode);

        Snap memory before = _snap(a);
        ok = _callAs(client, a, "triggerArbiterTimeout()");

        if (ok) {
            assertEq(usdc.balanceOf(client) - before.clientBal, DEAL, "arbiter at fault -> all to client");
            assertEq(usdc.balanceOf(address(a)), 0, "escrow must be empty");
        } else {
            assertEq(usdc.balanceOf(address(a)), before.escrowBal, "escrow untouched on revert");
        }
    }

    function testArbiterTimeoutClaimed_Alive_MoneyOut() public {
        assertTrue(_runArbiterTimeoutClaimed(Kill.ALIVE), "baseline: works while alive");
    }

    function testArbiterTimeoutClaimed_SelectorsRemoved_MoneyOut() public {
        assertTrue(_runArbiterTimeoutClaimed(Kill.SELECTORS_REMOVED), "money must come home");
    }

    function testArbiterTimeoutClaimed_FacetReverts_MoneyOut() public {
        assertTrue(_runArbiterTimeoutClaimed(Kill.FACET_REVERTS), "money must come home");
    }

    function testArbiterTimeoutClaimed_NoCode_MoneyOut() public {
        assertTrue(_runArbiterTimeoutClaimed(Kill.NO_CODE), "money must come home");
    }

    // ============================================================
    //  9. THE HATCH IS THE ONLY DOOR — AND IT OPENS
    // ============================================================
    //
    // Two halves of one statement, measured together because each is
    // worthless without the other. First: once disputedAt != 0 every other
    // door really is shut, so the hatch carries the whole promise. Second:
    // with the diamond silent, the hatch opens and the pot leaves.
    //
    // Before the fix the second half read assertFalse — that was the hole.

    function _assertHatchIsTheOnlyDoorAndItOpens(Kill mode) internal {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        _kill(mode);
        uint256 escrowBefore = usdc.balanceOf(address(a));
        assertEq(escrowBefore, DEAL, "precondition: the pot is in the clone");

        assertFalse(_callAs(client,   a, "release()"),                 "release must not open a disputed deal");
        assertFalse(_callAs(stranger, a, "triggerAutoApprove()"),      "auto-approve is closed once disputed");
        assertFalse(_callAs(client,   a, "triggerDeadlineTimeout()"),  "deadline timeout is closed once disputed");
        assertFalse(_callAs(client,   a, "triggerActivationTimeout()"),"activation timeout needs !activated");
        assertFalse(_callAs(executor, a, "triggerAutoApprove()"),      "auto-approve is closed once disputed");

        // resolveDispute is reachable only through the diamond
        // (claimDispute makes the DIAMOND the arbiter), so a dead diamond
        // closes it by construction.
        assertFalse(_callAs(arbiterAddr, a, "resolveDispute(bool)"), "arbiter cannot resolve directly");
        (bool okRes, ) = address(a).call(abi.encodeWithSignature("resolveDispute(bool)", true));
        assertFalse(okRes, "nobody can resolve without the diamond");

        assertEq(usdc.balanceOf(address(a)), escrowBefore, "no other door moved the pot");

        // ...and the one door that is left does open.
        Snap memory before = _snap(a);
        assertTrue(_callAs(client, a, "triggerArbiterTimeout()"), "the only hatch must open");
        assertEq(usdc.balanceOf(client)   - before.clientBal,   DEAL_HALF, "client half");
        assertEq(usdc.balanceOf(executor) - before.executorBal, DEAL_HALF, "executor half");
        assertEq(usdc.balanceOf(address(a)), 0, "escrow must be empty");
    }

    function testHatchIsTheOnlyDoorAndItOpens_SelectorsRemoved() public {
        _assertHatchIsTheOnlyDoorAndItOpens(Kill.SELECTORS_REMOVED);
    }

    function testHatchIsTheOnlyDoorAndItOpens_FacetReverts() public {
        _assertHatchIsTheOnlyDoorAndItOpens(Kill.FACET_REVERTS);
    }

    function testHatchIsTheOnlyDoorAndItOpens_NoCode() public {
        _assertHatchIsTheOnlyDoorAndItOpens(Kill.NO_CODE);
    }

    /// A party can still raise a dispute while the diamond is down —
    /// raiseDispute reaches the diamond only through _updateRegistry, which is
    /// tolerated. That used to be a trap: entering DISPUTED during an outage
    /// meant entering a state with no exit, and nothing warned anyone. It is
    /// no longer a trap, and this measures exactly that: raise it mid-outage,
    /// then walk back out with the money.
    function _assertDisputeRaisedMidOutageStillHasAWayOut(Kill mode) internal {
        Agreement a = _activated();
        _kill(mode);
        _assertDiamondReallyDeaf(mode);

        assertTrue(_callAs(client, a, "raiseDispute()"), "a party can still enter a dispute during an outage");

        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        Snap memory before = _snap(a);
        assertTrue(_callAs(client, a, "triggerArbiterTimeout()"), "and can get back out again");
        assertEq(usdc.balanceOf(client)   - before.clientBal,   DEAL_HALF, "client half");
        assertEq(usdc.balanceOf(executor) - before.executorBal, DEAL_HALF, "executor half");
        assertEq(usdc.balanceOf(address(a)), 0, "pot released");
    }

    function testDisputeRaisedMidOutageStillHasAWayOut_SelectorsRemoved() public {
        _assertDisputeRaisedMidOutageStillHasAWayOut(Kill.SELECTORS_REMOVED);
    }

    function testDisputeRaisedMidOutageStillHasAWayOut_FacetReverts() public {
        _assertDisputeRaisedMidOutageStillHasAWayOut(Kill.FACET_REVERTS);
    }

    function testDisputeRaisedMidOutageStillHasAWayOut_NoCode() public {
        _assertDisputeRaisedMidOutageStillHasAWayOut(Kill.NO_CODE);
    }

    // ============================================================
    //  10. THE CATCH BRANCH REALLY RAN
    // ============================================================
    //
    // "Money got out" alone would also be true if the diamond call never
    // happened. These assert the fallback was exercised: the registry did
    // NOT advance, and RegistrySyncFailed fired.

    function testReleaseUnderDeadDiamondLeavesRegistryStaleAndSaysSo() public {
        Agreement a = _markedDone();
        uint8 statusBefore = _registryStatus(a);
        assertEq(statusBefore, 0, "precondition: registry says ACTIVE");

        _kill(Kill.FACET_REVERTS);
        vm.recordLogs();
        vm.prank(client);
        a.release();

        assertTrue(_registrySyncFailedFired(), "the catch branch must announce itself");
        assertEq(_registryStatus(a), 0, "registry must be left stale, proving the call failed");
        assertEq(usdc.balanceOf(executor), DEAL, "and the money still left the clone");
    }

    /// The NO_CODE twin of the test above, and the proof that the new
    /// `diamond.code.length` branch is what carries mode C. If Agreement had
    /// instead started calling a codeless address low-level and calling that
    /// success, the money would still be out — and the registry would be
    /// silently wrong. RegistrySyncFailed is what tells the two apart.
    function testCodelessDiamondPaysOutAndStillAnnouncesTheStaleRegistry() public {
        Agreement a = _markedDone();
        assertEq(_registryStatus(a), 0, "precondition: registry says ACTIVE");

        _kill(Kill.NO_CODE);
        vm.recordLogs();
        vm.prank(client);
        a.release();

        assertTrue(_registrySyncFailedFired(), "the codeless branch must announce itself");
        assertEq(usdc.balanceOf(executor), DEAL, "and the money still left the clone");
    }

    /// Renamed 2026-08-23: it is no longer silent. The skip now fires
    /// XpAwardFailed, which is the only thing standing between "the executor's
    /// XP went missing" and anyone finding out. Both halves are asserted --
    /// drop the event and the first assertion goes red.
    function testXpIsSkippedButAnnouncedWhenDiamondIsDead() public {
        Agreement a = _markedDone();
        _kill(Kill.SELECTORS_REMOVED);

        vm.recordLogs();
        vm.prank(client);
        a.release();
        assertTrue(_xpAwardFailedFired(), "a skipped XP award must announce itself");

        // The XP selector is gone, so it cannot be read through the diamond;
        // remount just the getter to observe the storage the facet writes.
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = ReputationFacet.autoAwardXP.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(address(new ReputationFacet()), IDiamondCut.FacetCutAction.Add, sels);
        DiamondCutFacet(address(diamond)).diamondCut(cut, address(0), "");

        assertEq(ReputationFacet(address(diamond)).getXP(executor), 0, "no XP was awarded");
        assertEq(usdc.balanceOf(executor), DEAL, "but the money still left the clone");
    }

    // ============================================================
    //  11. syncRegistry() — bare ON PURPOSE
    // ============================================================
    //
    // Same registry call as the one inside _complete, which IS tolerated —
    // and this one is deliberately not. syncRegistry moves no money; it is the
    // repair tool a monitor reaches for after a RegistrySyncFailed. A tolerant
    // version would answer "done" while the registry stayed wrong, which is
    // the one answer a repair tool must never give. So it keeps failing loudly
    // when the diamond is down, and this test pins that decision in place.

    function testSyncRegistryIsBareAndDiesWithTheDiamond() public {
        Agreement a = _markedDone();
        vm.prank(client);
        a.release();

        assertTrue(_call(a, "syncRegistry()"), "baseline: syncRegistry works while alive");

        Agreement b = _markedDone();
        _kill(Kill.FACET_REVERTS);
        vm.prank(client);
        b.release();
        assertFalse(_call(b, "syncRegistry()"), "MEASURED: the syncRegistry call in Agreement is bare");
    }

    // ============================================================
    //  12. THE GAS TRAP - try/catch does not survive a gas eater
    // ============================================================
    //
    // try/catch converts a revert into a caught failure, but it cannot give
    // back gas the callee already burned. EIP-150 hands the callee 63/64 of
    // what is left; the diamond adds a second frame (proxy -> delegatecall),
    // so each logical diamond call costs the Agreement about 1/32 of its
    // remaining gas when the facet eats everything.
    //
    // Agreement._complete makes TWO such calls in a row BEFORE the transfer
    // (_updateRegistry, then autoAwardXP). Measured leftovers from a 30M
    // budget, BEFORE the caps of 2026-08-23:
    // 29_999_784 -> 929_412 -> 28_067.
    //
    // A facet that consumes all the gas is not exotic: any unbounded loop
    // over data that keeps growing gets there on its own.
    //
    // FIXED 2026-08-23. Every tolerated diamond call now carries a measured
    // {gas: ...} cap, so the loss to a gas eater is a fixed, known amount
    // instead of 63/64 of the transaction. Sections 14-17 below are the locks
    // on that; the two tests in this section kept their setup and flipped
    // their sign.

    uint256 constant REALISTIC_GAS = 1_000_000; // generous wallet budget, hand-picked
    uint256 constant HUGE_GAS      = 30_000_000;

    function _mountGasBurner() internal {
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = bytes4(keccak256("updateStatus(address,uint8)"));
        sels[1] = bytes4(keccak256("autoAwardXP(address)"));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
            address(new GasBurnerFacet()), IDiamondCut.FacetCutAction.Replace, sels
        );
        DiamondCutFacet(address(diamond)).diamondCut(cut, address(0), "");
    }

    function _autoApproveWithGas(uint256 gasBudget, bool burner) internal returns (bool ok) {
        Agreement a = _markedDone();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);
        if (burner) _mountGasBurner();
        vm.prank(stranger);
        (ok, ) = address(a).call{gas: gasBudget}(abi.encodeWithSignature("triggerAutoApprove()"));
        if (ok) assertEq(usdc.balanceOf(executor), DEAL, "executor paid");
        else    assertEq(usdc.balanceOf(address(a)), DEAL, "pot stayed in the clone");
    }

    /// The independent half of the comparison: REALISTIC_GAS is NOT an
    /// artificially small number. With a healthy diamond the very same call
    /// completes inside it (measured cost ~419_481 gas).
    function testAutoApproveFitsInARealisticGasBudgetWhenDiamondIsHealthy() public {
        assertTrue(
            _autoApproveWithGas(REALISTIC_GAS, false),
            "baseline: 1M gas is plenty for auto-approve on a healthy diamond"
        );
    }

    /// The measurement that used to record the defect, with its sign flipped
    /// by the caps. Before 2026-08-23 this asserted assertFalse and passed.
    function testGasBurningFacetNoLongerBlocksAutoApproveAtARealisticGasBudget() public {
        assertTrue(
            _autoApproveWithGas(REALISTIC_GAS, true),
            "a capped diamond call cannot drag auto-approve past a realistic gas budget"
        );
    }

    /// Same setup at an absurd budget. Green before the caps and after them;
    /// kept because it is the half of the comparison that isolates gas
    /// arithmetic from every other reason a call might revert.
    function testGasBurningFacetIsBeatenOnlyByAnAbsurdGasBudget() public {
        assertTrue(
            _autoApproveWithGas(HUGE_GAS, true),
            "with 30M gas the leftover finally covers the transfer"
        );
    }

    /// A refund path makes only ONE diamond call before the transfer
    /// (notifyExecutorFault comes AFTER the money), so it loses ~1/32 once
    /// and survives. Recorded because it shows the damage scales with how
    /// many diamond calls sit in front of the payout.
    function testGasBurningFacetDoesNotBlockActivationTimeout() public {
        Agreement a = _createFundedAgreement();
        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);
        _mountGasBurner();

        vm.prank(client);
        (bool ok, ) = address(a).call{gas: REALISTIC_GAS}(
            abi.encodeWithSignature("triggerActivationTimeout()")
        );

        assertTrue(ok, "one burn only costs ~1/32 - enough left to pay out");
        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
    }

    // ============================================================
    //  13. THE OTHER HALF OF THE BARGAIN — A LIVE DIAMOND STILL BLOCKS
    // ============================================================
    //
    // Everything above says "a silent diamond must not lock the money in".
    // The check being fixed has a real job as well: while an arbiter's verdict
    // is in flight (FINALIZE_DELAY, appeal voting) a party must NOT be able to
    // force a refund and wipe the other arbiters' vote out. Section 13 is the
    // set of locks on that job, so the cure cannot quietly become "the check
    // never fires".
    //
    // Where the expectation comes from: a verdict is put in flight by actually
    // calling submitVerdict through the diamond — an action, not a reading of
    // the same slot the contract reads. The expected outcomes are hand-written
    // custom-error selectors.

    /// Deal in dispute, claimed by the arbiter, verdict SUBMITTED but not yet
    /// finalized. submitVerdict must land inside DISPUTE_WINDOW, so the warp
    /// past the window happens after it, in the callers.
    function _disputedWithVerdictSubmitted() internal returns (Agreement a) {
        a = _activated();
        vm.prank(client);
        a.raiseDispute();
        _claimByArbiter(a);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);
    }



    /// The behaviour that must NOT have changed: healthy diamond, live
    /// verdict, window elapsed — the hatch stays shut, and shuts with the same
    /// error as before.
    function testLiveVerdictStillBlocksTheHatch() public {
        Agreement a = _disputedWithVerdictSubmitted();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        vm.prank(client);
        (bool ok, bytes memory ret) = address(a).call(
            abi.encodeWithSignature("triggerArbiterTimeout()")
        );

        assertFalse(ok, "a live verdict must still block the timeout");
        assertEq(
            _revertSelector(ret),
            Agreement.VerdictInFlight.selector,
            "and it must be VerdictInFlight that blocks it"
        );
        assertEq(usdc.balanceOf(address(a)), DEAL, "the pot stayed in the clone");
    }

    /// The attack the gas cap invites and the gas floor closes.
    ///
    /// A failed read means "no verdict", so a party who could make the read
    /// run out of gas — while leaving enough for the payout — would force a
    /// refund straight through a live verdict on a perfectly healthy diamond.
    /// Agreement refuses to read at all unless it can hand over the full cap.
    ///
    /// Two things are asserted, and they are not the same thing: (1) NO gas
    /// budget at all lets the money out, and (2) the budgets below the floor
    /// are refused BY THE FLOOR — NotEnoughGasForVerdictCheck — rather than
    /// answered by a guess. Drop the floor and (2) goes red.
    function testGasStarvationCannotForceTheHatchPastALiveVerdict() public {
        Agreement a = _disputedWithVerdictSubmitted();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        assertEq(usdc.balanceOf(address(a)), DEAL, "precondition: the pot is in the clone");

        bool sawFloorRefusal;
        for (uint256 g = 40_000; g <= 400_000; g += 4_000) {
            vm.prank(client);
            (bool ok, bytes memory ret) = address(a).call{gas: g}(
                abi.encodeWithSignature("triggerArbiterTimeout()")
            );
            assertFalse(ok, "no gas budget may open the hatch past a live verdict");
            assertEq(usdc.balanceOf(address(a)), DEAL, "and the pot never moves");
            if (_revertSelector(ret) == Agreement.NotEnoughGasForVerdictCheck.selector) {
                sawFloorRefusal = true;
            }
        }
        assertTrue(sawFloorRefusal, "below the floor the contract must refuse to read, not guess");
    }

    /// What the cap is measured against. The number is the real cost of the
    /// read through the proxy with EVERYTHING cold — diamond account, the
    /// facet-address slot, the facet account, the verdict slot — because
    /// nothing in this test body touches the diamond before the probe runs.
    ///
    /// The cap literal below is hand-copied from Agreement.VERDICT_VIEW_GAS on
    /// purpose: reading it back out of the contract under test would make this
    /// assertion look at itself. A cap set too LOW is caught by behaviour, not
    /// by this test — testLiveVerdictStillBlocksTheHatch goes red the moment
    /// the read stops fitting in its budget.
    uint256 constant VERDICT_VIEW_GAS_CAP = 100_000; // = Agreement.VERDICT_VIEW_GAS

    function testVerdictViewCostSitsFarUnderTheCap() public {
        VerdictViewProbe probe = new VerdictViewProbe(address(diamond));
        (uint256 used, bool ok, uint256 word) = probe.measure(address(0xCAFE01));

        assertTrue(ok, "the read must actually answer, otherwise this measures nothing");
        assertEq(word, 0, "an address with no dispute must read as no verdict");
        emit log_named_uint("hasSubmittedVerdict through the diamond, all cold", used);
        assertLt(used * 4, VERDICT_VIEW_GAS_CAP, "the cap must keep at least 4x headroom over the real cost");
    }

    /// The gas cap earns its keep here: a facet that eats gas on the verdict
    /// selector cannot drag the hatch down with it. Without the cap the read
    /// would be handed 63/64 of the transaction and nothing would be left to
    /// pay anyone.
    function testGasBurningVerdictFacetCannotBlockTheHatch() public {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("hasSubmittedVerdict(address)"));
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(
            address(new GasBurnerFacet()), IDiamondCut.FacetCutAction.Replace, sels
        );
        DiamondCutFacet(address(diamond)).diamondCut(cut, address(0), "");

        Snap memory before = _snap(a);
        vm.prank(client);
        (bool ok, ) = address(a).call{gas: REALISTIC_GAS}(
            abi.encodeWithSignature("triggerArbiterTimeout()")
        );

        assertTrue(ok, "a capped read cannot be starved into taking the whole transaction");
        assertEq(usdc.balanceOf(client)   - before.clientBal,   DEAL_HALF, "client half");
        assertEq(usdc.balanceOf(executor) - before.executorBal, DEAL_HALF, "executor half");
        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
    }
}
