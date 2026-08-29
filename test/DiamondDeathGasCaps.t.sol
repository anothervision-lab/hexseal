// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  DIAMOND-CALL GAS CAPS  —  sections 14-17
// ============================================================
//
// Same fixture as test/DiamondDeathEscrow.t.sol, same three ways of killing
// the diamond. This half is about the fourth way, which is not a kill at all:
// a facet that answers by EATING GAS. try/catch turns a revert into a caught
// failure but cannot give back gas the callee already burned, so before
// 2026-08-23 one such facet inflated the cost of closing a deal 71-fold and
// no amount of error handling in Agreement could have stopped it.
//
// The cure is a measured {gas: ...} cap on every diamond call Agreement
// tolerates, plus a gasleft() floor on the two whose failure is worth
// something to the caller. These four sections are the locks on both halves:
// section 14 keeps the caps honest against the real cost, 15 keeps the honest
// path working at the budgets the product actually ships, 16 keeps a gas eater
// away from the money, 17 keeps a hand-picked gas limit from quietly costing
// someone else their XP or their fee.

import "./DiamondDeathEscrowBase.sol";

contract DiamondDeathGasCapsTest is DiamondDeathEscrowBase {
    // ============================================================
    //  14. WHAT EACH CAP IS MEASURED AGAINST
    // ============================================================
    //
    // Every {gas: ...} cap in Agreement is a hand-picked number, and a cap set
    // too LOW is the expensive failure: the call quietly fails, the deal
    // closes anyway, and the registry or the XP is silently wrong. So the real
    // cost of all six capped calls is re-measured on every run here, against
    // the real facets through the real proxy, with vm.cool() putting the
    // diamond account, the facet-address slot and the facet itself back to
    // cold -- the state every one of these calls is in when it is made for
    // real, because a fresh transaction starts cold.
    //
    // The cap literals below are hand-copied from src/Agreement.sol. Reading
    // them back out of the contract under test would make this a mirror: the
    // expected value and the measured value would come from the same place and
    // the assertion could never fail: an expectation derived from the thing it
    // checks agrees with itself always.
    //
    // A cap set too low is NOT caught here -- it is caught by behaviour, in
    // section 15: the honest path stops updating the registry or awarding XP.

    uint256 constant CAP_REGISTRY_UPDATE = 150_000; // = Agreement.REGISTRY_UPDATE_GAS
    uint256 constant CAP_XP_AWARD        = 500_000; // = Agreement.XP_AWARD_GAS
    uint256 constant CAP_DISPUTE_FEE     = 150_000; // = Agreement.DISPUTE_FEE_GAS
    uint256 constant CAP_FAULT_NOTIFY    = 100_000; // = Agreement.FAULT_NOTIFY_GAS
    uint256 constant CAP_ARBITER_TIMEOUT = 150_000; // = Agreement.ARBITER_TIMEOUT_GAS
    uint256 constant CAP_CLAIM_CLEAR     = 200_000; // = Agreement.CLAIM_CLEAR_GAS
    uint256 constant CAP_FEE_READ        = 100_000; // = Agreement.FEE_READ_GAS









    /// The two fee-model views the top-up reads, through the real proxy with
    /// every slot cold. They are the cheapest calls Agreement makes -- one
    /// storage word each, no writes -- and the cap is deliberately the same
    /// number the verdict view uses, because they are the same class of read.
    ///
    /// A cap set too low here does NOT quietly lose anything, which is the
    /// difference from the six above: the read reverts FeeUnavailable and the
    /// top-up does not happen. It is measured anyway, because "the button
    /// stopped working" is a bad way to find out.
    function testFeeModelReadsSitUnderTheirCap() public {
        Agreement a = _activated();

        uint256 bpsCost = _measureAsAgreement(a, abi.encodeWithSignature("getFeeBps()"));
        _assertUnderCap("getFeeBps(), all cold", bpsCost, CAP_FEE_READ);
        assertLt(bpsCost * 4, CAP_FEE_READ, "and keep at least 4x headroom");

        uint256 toCost = _measureAsAgreement(a, abi.encodeWithSignature("getFeeRecipient()"));
        _assertUnderCap("getFeeRecipient(), all cold", toCost, CAP_FEE_READ);
        assertLt(toCost * 4, CAP_FEE_READ, "and keep at least 4x headroom");
    }

    function testRegistryUpdateCostSitsUnderItsCap() public {
        Agreement a = _activated();
        uint256 used = _measureAsAgreement(
            a, abi.encodeWithSignature("updateStatus(address,uint8)", address(a), uint8(1))
        );
        _assertUnderCap("updateStatus -> COMPLETED, all cold", used, CAP_REGISTRY_UPDATE);
        assertLt(used * 2, CAP_REGISTRY_UPDATE, "and keep at least 2x headroom");
    }

    /// The heaviest of the six, and the one whose cap sets the minimum gas
    /// limit for release(). Worst case by construction: a brand-new pair's
    /// FIRST completed deal, which writes fresh XP, streak, pair and
    /// unique-user storage for both sides at once.
    ///
    /// Built by taking autoAwardXP off the diamond, completing the deal (the
    /// award is skipped, the "claimed" flags stay unset), then putting the
    /// selector back and making the call the clone would have made.
    function testXpAwardCostSitsUnderItsCap() public {
        bytes4 sel = ReputationFacet.autoAwardXP.selector;
        address rep = _facetOf(sel);
        _mountOne(address(0), sel, IDiamondCut.FacetCutAction.Remove);

        Agreement a = _markedDone();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);
        vm.prank(stranger);
        a.triggerAutoApprove();
        assertEq(ReputationFacet(address(diamond)).getXP(executor), 0, "precondition: no XP yet");

        _mountOne(rep, sel, IDiamondCut.FacetCutAction.Add);
        uint256 used = _measureAsAgreement(a, abi.encodeWithSignature("autoAwardXP(address)", address(a)));

        _assertUnderCap("autoAwardXP, first deal of a new pair, all cold", used, CAP_XP_AWARD);
        assertGt(ReputationFacet(address(diamond)).getXP(executor), 0, "the award really happened");
    }

    function testDisputeFeeCreditCostSitsUnderItsCap() public {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        _claimByArbiter(a);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);

        uint256 used = _measureAsAgreement(
            a, abi.encodeWithSignature("creditDisputeFee(uint256)", uint256(30_000_000))
        );
        _assertUnderCap("creditDisputeFee, all cold", used, CAP_DISPUTE_FEE);
        assertLt(used * 2, CAP_DISPUTE_FEE, "and keep at least 2x headroom");
    }

    function testExecutorFaultNoticeCostSitsUnderItsCap() public {
        Agreement a = _activated();
        uint256 used = _measureAsAgreement(
            a, abi.encodeWithSignature("notifyExecutorFault(address)", address(a))
        );
        _assertUnderCap("notifyExecutorFault, all cold", used, CAP_FAULT_NOTIFY);
    }

    function testArbiterTimeoutNoticeCostSitsUnderItsCap() public {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        _claimByArbiter(a);
        uint256 used = _measureAsAgreement(
            a, abi.encodeWithSignature("notifyArbiterTimeout(address)", address(a))
        );
        _assertUnderCap("notifyArbiterTimeout, claimed dispute, all cold", used, CAP_ARBITER_TIMEOUT);
    }

    function testClaimClearCostSitsUnderItsCap() public {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        _claimByArbiter(a);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);
        uint256 used = _measureAsAgreement(
            a, abi.encodeWithSignature("clearDisputeClaim(address)", address(a))
        );
        _assertUnderCap("clearDisputeClaim, claim + stuck verdict, all cold", used, CAP_CLAIM_CLEAR);
    }

    // ============================================================
    //  15. THE REGRESSION THAT MATTERS MORE THAN THE FIX
    // ============================================================
    //
    // A cap that is too tight, or a gasleft() floor that asks for more than a
    // wallet ever offers, does not announce itself: the deal still closes, the
    // money still moves, and only the registry and the XP quietly stop being
    // true. So every one of the SEVEN places _complete() is reached from is
    // driven here on a perfectly healthy diamond, at the gas ceiling the
    // product itself ships, and the registry row and the XP are read back.
    //
    // WHERE THE BUDGETS COME FROM. They are hand-copied from the relay client's
    // fallback gas table, GAS_DEFAULTS -- the ceilings that table
    // carried BEFORE this change, i.e. the ones live wallets have been using.
    // That is the honest bar: if the honest path fits inside the OLD ceiling,
    // this change costs no downstream migration. (GAS_DEFAULTS is a fallback,
    // used whenever eth_estimateGas fails; the estimate path would simply
    // quote the higher number by itself.)
    //
    // Registry status codes are RegistryFacet.AgreementStatus, written out as
    // literals: ACTIVE 0, COMPLETED 1, REFUNDED 2, DISPUTED 3, RESOLVED 4.

    // GAS_DEFAULTS as it stood BEFORE the caps landed. Four of these have
    // since been raised in relay.ts for margin, which makes the bar here the
    // harder of the two on purpose: fitting inside the OLD ceiling is what
    // "this change needs no downstream migration" means. Raising them further
    // must never be what makes this suite pass.
    uint256 constant SHIPPED_RELEASE_GAS            = 660_000; // relay.ts release, pre-2026-08-23
    uint256 constant SHIPPED_AUTO_APPROVE_GAS       = 660_000; // relay.ts triggerAutoApprove, pre-2026-08-23
    uint256 constant SHIPPED_RAISE_DISPUTE_GAS      = 160_000; // relay.ts raiseDispute, unchanged
    uint256 constant SHIPPED_ACTIVATION_TIMEOUT_GAS = 210_000; // relay.ts triggerActivationTimeout, unchanged
    uint256 constant SHIPPED_DEADLINE_TIMEOUT_GAS   = 220_000; // relay.ts triggerDeadlineTimeout, unchanged
    uint256 constant SHIPPED_ARBITER_TIMEOUT_GAS    = 500_000; // relay.ts triggerArbiterTimeout, unchanged
    uint256 constant SHIPPED_FINALIZE_VERDICT_GAS   = 780_000; // relay.ts finalizeVerdict, pre-2026-08-23



    /// Site 1 of 7 — Agreement.release().
    function testSite1_ReleaseAtShippedBudgetKeepsRegistryAndXpTrue() public {
        Agreement a = _markedDone();
        vm.recordLogs();
        assertTrue(_callWithGas(client, a, SHIPPED_RELEASE_GAS, "release()"), "release must fit");

        assertEq(usdc.balanceOf(executor), DEAL, "executor paid");
        assertEq(_registryStatus(a), 1, "registry must say COMPLETED, not stay ACTIVE");
        assertFalse(_registrySyncFailedFired(), "and it must not have fallen back to the stale branch");
        assertGt(ReputationFacet(address(diamond)).getXP(executor), 0, "executor XP");
        assertGt(ReputationFacet(address(diamond)).getXP(client), 0, "client XP");
    }

    /// Site 2 of 7 — Agreement.markDone(), triggerAutoApprove().
    function testSite2_AutoApproveAtShippedBudgetKeepsRegistryAndXpTrue() public {
        Agreement a = _markedDone();
        vm.warp(block.timestamp + AUTO_APPROVE_WINDOW + 1);
        vm.recordLogs();
        assertTrue(
            _callWithGas(stranger, a, SHIPPED_AUTO_APPROVE_GAS, "triggerAutoApprove()"),
            "auto-approve must fit"
        );

        assertEq(usdc.balanceOf(executor), DEAL, "executor paid");
        assertEq(_registryStatus(a), 1, "registry must say COMPLETED");
        assertFalse(_registrySyncFailedFired(), "no stale-registry fallback");
        assertGt(ReputationFacet(address(diamond)).getXP(executor), 0, "executor XP");
        assertGt(ReputationFacet(address(diamond)).getXP(client), 0, "client XP");
    }

    /// Site 3 of 7 — Agreement.raiseDispute(), resolveDispute(), reached the way the
    /// product reaches it: finalizeVerdict on the diamond, at the diamond's
    /// own shipped ceiling. This is also the only site where creditDisputeFee
    /// stands in front of the payout.
    function testSite3_ResolveDisputeAtShippedBudgetKeepsRegistryAndXpTrue() public {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        _claimByArbiter(a);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);
        vm.warp(block.timestamp + 3 days);

        vm.recordLogs();
        (bool ok, ) = address(diamond).call{gas: SHIPPED_FINALIZE_VERDICT_GAS}(
            abi.encodeWithSignature("finalizeVerdict(address)", address(a))
        );
        assertTrue(ok, "finalizeVerdict must fit its shipped ceiling");

        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
        assertEq(_registryStatus(a), 4, "registry must say RESOLVED");
        assertFalse(_registrySyncFailedFired(), "no stale-registry fallback");
        assertGt(ReputationFacet(address(diamond)).getXP(client), 0, "the winner's XP landed");
        assertGt(
            ArbiterRegistryFacet(address(diamond)).getVaultBalance()
                + ArbiterRegistryFacet(address(diamond)).getTreasurySlice(),
            0,
            "the dispute fee was credited, not starved out"
        );
    }

    /// Site 4 of 7 — Agreement.resolveDispute(), triggerActivationTimeout().
    function testSite4_ActivationTimeoutAtShippedBudgetKeepsRegistryTrue() public {
        Agreement a = _createFundedAgreement();
        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);
        vm.recordLogs();
        assertTrue(
            _callWithGas(client, a, SHIPPED_ACTIVATION_TIMEOUT_GAS, "triggerActivationTimeout()"),
            "activation timeout must fit"
        );
        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
        assertEq(_registryStatus(a), 2, "registry must say REFUNDED");
        assertFalse(_registrySyncFailedFired(), "no stale-registry fallback");
    }

    /// Site 5 of 7 — Agreement.triggerArbiterTimeout(), triggerDeadlineTimeout().
    function testSite5_DeadlineTimeoutAtShippedBudgetKeepsRegistryTrue() public {
        Agreement a = _activated();
        vm.warp(block.timestamp + DEADLINE_DAYS * 1 days + DEADLINE_GRACE + 1);
        vm.recordLogs();
        assertTrue(
            _callWithGas(client, a, SHIPPED_DEADLINE_TIMEOUT_GAS, "triggerDeadlineTimeout()"),
            "deadline timeout must fit"
        );
        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
        assertEq(_registryStatus(a), 2, "registry must say REFUNDED");
        assertFalse(_registrySyncFailedFired(), "no stale-registry fallback");
    }

    /// Site 6 of 7 — Agreement._complete(), triggerArbiterTimeout(), the branch
    /// nobody claimed: the pot is split by attendance and _clearDisputeClaim
    /// stands after the money.
    function testSite6_ArbiterTimeoutUnclaimedAtShippedBudgetKeepsRegistryTrue() public {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.recordLogs();
        assertTrue(
            _callWithGas(client, a, SHIPPED_ARBITER_TIMEOUT_GAS, "triggerArbiterTimeout()"),
            "arbiter timeout (unclaimed) must fit"
        );
        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
        assertEq(_registryStatus(a), 2, "registry must say REFUNDED");
        assertFalse(_registrySyncFailedFired(), "no stale-registry fallback");
    }

    /// Site 7 of 7 — Agreement.syncRegistry(), triggerArbiterTimeout(), the branch
    /// an arbiter claimed and abandoned: refund to the client, then TWO
    /// diamond calls after the money (notifyArbiterTimeout, clearDisputeClaim).
    function testSite7_ArbiterTimeoutClaimedAtShippedBudgetKeepsRegistryTrue() public {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        _claimByArbiter(a);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.recordLogs();
        assertTrue(
            _callWithGas(client, a, SHIPPED_ARBITER_TIMEOUT_GAS, "triggerArbiterTimeout()"),
            "arbiter timeout (claimed) must fit"
        );
        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
        assertEq(_registryStatus(a), 2, "registry must say REFUNDED");
        assertFalse(_registrySyncFailedFired(), "no stale-registry fallback");
        assertEq(
            ArbiterRegistryFacet(address(diamond)).getDisputeClaimer(address(a)),
            address(0),
            "the claim was cleared, not starved out"
        );
    }

    /// The eighth diamond write, the only one outside _complete: raiseDispute
    /// moves no money but does update the registry, and it ships the tightest
    /// ceiling of the lot (160_000). This is the entry a floor on
    /// _updateRegistry would have broken.
    function testRaiseDisputeAtShippedBudgetKeepsRegistryTrue() public {
        Agreement a = _activated();
        vm.recordLogs();
        assertTrue(
            _callWithGas(client, a, SHIPPED_RAISE_DISPUTE_GAS, "raiseDispute()"),
            "raiseDispute must fit its shipped ceiling"
        );
        assertEq(_registryStatus(a), 3, "registry must say DISPUTED");
        assertFalse(_registrySyncFailedFired(), "no stale-registry fallback");
    }

    // ============================================================
    //  16. A GAS EATER CANNOT REACH THE MONEY ANY MORE
    // ============================================================
    //
    // One burner per capped call, so a failure names the cap that is missing
    // rather than "something about gas". Budgets are the shipped ceilings from
    // section 15 -- not a generous round number -- because that is what the
    // guarantee is worth in practice.
    //
    // What the SAME call costs once the diamond answers by eating gas: every
    // capped call takes its whole cap instead of its honest cost, and on the
    // release path the floor in front of autoAwardXP has to be satisfied out
    // of what the earlier burner left. MEASURED minimum budgets with all six
    // capped selectors burning:
    //
    //   release                   712_018   (shipped ceiling 660_000)
    //   finalizeVerdict         1_134_325   (shipped ceiling 780_000)
    //   triggerArbiterTimeout     467_710   (shipped ceiling 500_000, fits)
    //   triggerActivationTimeout  285_277   (shipped ceiling 210_000)
    //   raiseDispute              138_322   (shipped ceiling 160_000, fits)
    //
    // So a wholly gas-eating diamond does push three of these past the
    // FALLBACK ceilings in relay.ts. That fallback is only reached when
    // eth_estimateGas itself failed; the estimate path simulates the call and
    // would quote the larger figure by itself. Before the caps the same three
    // needed ~30_000_000 and no quote could have saved them.

    uint256 constant BURNED_RELEASE_GAS  =   800_000;
    uint256 constant BURNED_FINALIZE_GAS = 1_300_000;

    /// The headline number, measured in one place so it cannot drift: what a
    /// gas-eating diamond does to the cost of closing an ordinary deal. Before
    /// the caps it was 419_481 -> 29_791_258, a factor of 71, i.e. more than a
    /// whole block. The bound asserted here is a hand-written 2x.
    function testAGasEaterCanNoLongerInflateTheCostOfClosingADeal() public {
        uint256 snap = vm.snapshotState();

        Agreement healthyDeal = _markedDone();
        vm.prank(client);
        uint256 g0 = gasleft();
        healthyDeal.release();
        uint256 healthy = g0 - gasleft();

        vm.revertToState(snap);

        Agreement burnedDeal = _markedDone();
        _burnOn(bytes4(keccak256("updateStatus(address,uint8)")));
        _burnOn(bytes4(keccak256("autoAwardXP(address)")));
        _burnOn(bytes4(keccak256("creditDisputeFee(uint256)")));
        _burnOn(bytes4(keccak256("notifyArbiterTimeout(address)")));
        _burnOn(bytes4(keccak256("clearDisputeClaim(address)")));
        _burnOn(bytes4(keccak256("notifyExecutorFault(address)")));
        vm.prank(client);
        uint256 g1 = gasleft();
        burnedDeal.release();
        uint256 burned = g1 - gasleft();

        emit log_named_uint("release, healthy diamond", healthy);
        emit log_named_uint("release, every facet eating gas", burned);
        assertLt(burned, healthy * 2, "a gas eater must not be able to double the cost of a deal");
        assertEq(usdc.balanceOf(executor), DEAL, "and the executor was still paid in full");
    }



    /// Cap on _updateRegistry. The registry is allowed to go stale here --
    /// that is the trade the cap makes -- but it must say so, and the money
    /// must leave.
    function testBurningRegistryFacetCannotBlockRelease() public {
        Agreement a = _markedDone();
        _burnOn(bytes4(keccak256("updateStatus(address,uint8)")));

        vm.recordLogs();
        assertTrue(
            _callWithGas(client, a, BURNED_RELEASE_GAS, "release()"),
            "a capped registry write cannot take the payout down with it"
        );
        assertEq(usdc.balanceOf(executor), DEAL, "executor paid");
        assertTrue(_registrySyncFailedFired(), "and the stale registry announced itself");
    }

    /// Cap on autoAwardXP -- the single most expensive call in front of any
    /// payout, and the one that made auto-approve cost 71x.
    function testBurningXpFacetCannotBlockRelease() public {
        Agreement a = _markedDone();
        _burnOn(ReputationFacet.autoAwardXP.selector);

        vm.recordLogs();
        assertTrue(
            _callWithGas(client, a, BURNED_RELEASE_GAS, "release()"),
            "a capped XP award cannot take the payout down with it"
        );
        assertEq(usdc.balanceOf(executor), DEAL, "executor paid");
        assertEq(_registryStatus(a), 1, "the registry still moved");
        assertTrue(_xpAwardFailedFired(), "and the lost XP announced itself");
    }

    /// Both of _complete's calls burning at once, which is the shape the
    /// original measurement used.
    function testBothCompleteCallsBurningCannotBlockRelease() public {
        Agreement a = _markedDone();
        _burnOn(bytes4(keccak256("updateStatus(address,uint8)")));
        _burnOn(ReputationFacet.autoAwardXP.selector);

        assertTrue(
            _callWithGas(client, a, BURNED_RELEASE_GAS, "release()"),
            "two capped calls in a row still leave enough to pay"
        );
        assertEq(usdc.balanceOf(executor), DEAL, "executor paid");
    }

    /// Cap on creditDisputeFee, the one write that stands in front of the
    /// money on the verdict path.
    function testBurningFeeFacetCannotBlockResolveDispute() public {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        _claimByArbiter(a);
        vm.prank(arbiterAddr);
        ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);
        vm.warp(block.timestamp + 3 days);
        _burnOn(ArbiterRegistryFacet.creditDisputeFee.selector);

        uint256 clientBefore = usdc.balanceOf(client);
        (bool ok, ) = address(diamond).call{gas: BURNED_FINALIZE_GAS}(
            abi.encodeWithSignature("finalizeVerdict(address)", address(a))
        );
        assertTrue(ok, "a capped fee credit cannot take the payout down with it");
        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
        // The fee was not taken, so the WHOLE pot went to the winner -- the
        // documented meaning of a failed credit ("not collected", never
        // "burned"). A silently swallowed fee would show up here as a short
        // payout.
        assertEq(
            usdc.balanceOf(client) - clientBefore,
            DEAL,
            "the uncollected fee went to the winner, not nowhere"
        );
    }

    /// AFTER the money is not a safe place either, and this is the row the
    /// brief did not expect. triggerArbiterTimeout makes TWO diamond calls
    /// after the transfer; each uncapped burner eats ~31/32 of what is left,
    /// so two of them leave ~1/1024 and the transaction dies -- rolling the
    /// transfer back with it. MEASURED before the caps: this exact scene at
    /// 500_000 gas failed with the whole pot still in the clone.
    function testBurningFacetsAfterTheMoneyCannotBlockArbiterTimeout() public {
        Agreement a = _activated();
        vm.prank(client);
        a.raiseDispute();
        vm.prank(executor);
        a.respondToDispute();
        _claimByArbiter(a);
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        _burnOn(bytes4(keccak256("notifyArbiterTimeout(address)")));
        _burnOn(bytes4(keccak256("clearDisputeClaim(address)")));

        assertTrue(
            _callWithGas(client, a, SHIPPED_ARBITER_TIMEOUT_GAS, "triggerArbiterTimeout()"),
            "two capped calls behind the payout must not roll it back"
        );
        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
    }

    /// The same for the refund paths, whose one after-money call is
    /// notifyExecutorFault.
    function testBurningFaultNoticeCannotBlockActivationTimeout() public {
        Agreement a = _createFundedAgreement();
        vm.warp(block.timestamp + ACTIVATION_WINDOW + 1);
        _burnOn(bytes4(keccak256("notifyExecutorFault(address)")));

        assertTrue(
            _callWithGas(client, a, SHIPPED_ACTIVATION_TIMEOUT_GAS, "triggerActivationTimeout()"),
            "a capped fault notice must not roll the refund back"
        );
        assertEq(usdc.balanceOf(address(a)), 0, "escrow emptied");
    }

    // ============================================================
    //  17. THE FLOOR: NOBODY GETS TO PICK A GAS LIMIT THAT COSTS
    //      SOMEONE ELSE SOMETHING
    // ============================================================
    //
    // A cap on a tolerated call invites the opposite attack: hand-pick a gas
    // limit small enough that the capped call runs out, big enough that the
    // rest of the function still fits. The failure is caught, the deal closes,
    // and whoever picked the limit keeps the difference.
    //
    // Two calls are worth something to starve, and both are floored:
    //   * autoAwardXP     -- the counterparty's XP goes missing. XP gates the
    //                        arbiter roster (MIN_XP_TO_REGISTER), so this is a
    //                        way to hold back a rival's standing while
    //                        everything visible looks fine.
    //   * creditDisputeFee-- the arbiter's 3% stays in the pot the caller is
    //                        about to win.
    //
    // Both tests sweep a whole range of budgets rather than one hand-picked
    // number: the attack IS the search for the right number, so the lock has
    // to answer for every number in the band.
    //
    // HONEST NOTE ON WHAT THE FLOOR IS ACTUALLY BUYING. Measured: removing the
    // floor leaves testGasStarvationCannotRobTheExecutorOfXp GREEN, and that is
    // not a hole in the test -- it is arithmetic. To starve autoAwardXP the
    // call has to be reached with less than 332_268 * 64/63 ~= 338_000 gas, and
    // a failed capped call gives back only about 1/32 of what stood before it
    // (~10_500 here) while the transfer still needs ~30_000. So "the deal
    // closed" and "the XP went missing" cannot both be true today, floor or no
    // floor. The floor turns that coincidence into a stated invariant, which
    // is worth having because the ratio can move on its own -- autoAwardXP
    // getting cheaper, or the tail of the function getting dearer, is all it
    // would take. The test that actually goes red when the floor is deleted is
    // the one below it, and it goes red because it demands the refusal name
    // the call it refused.

    /// The client sweeps every budget between "not enough for anything" and
    /// "comfortably enough". At no point may the deal close while the
    /// executor's XP is missing.
    function testGasStarvationCannotRobTheExecutorOfXp() public {
        bool sawASuccess;
        for (uint256 g = 120_000; g <= SHIPPED_RELEASE_GAS; g += 10_000) {
            uint256 snap = vm.snapshotState();
            Agreement a = _markedDone();

            vm.prank(client);
            (bool ok, ) = address(a).call{gas: g}(abi.encodeWithSignature("release()"));

            if (ok) {
                sawASuccess = true;
                assertGt(
                    ReputationFacet(address(diamond)).getXP(executor),
                    0,
                    "a release that went through must not have skipped the executor's XP"
                );
            } else {
                assertEq(usdc.balanceOf(address(a)), DEAL, "and a refused release moves nothing");
            }
            vm.revertToState(snap);
        }
        // Anti-vacuous guard: a band in which nothing ever succeeds would make
        // the loop above assert nothing at all and still pass.
        assertTrue(sawASuccess, "the band must contain budgets that DO go through");
    }

    /// The refusal has to come from the floor, by name, and not from running
    /// out of gas somewhere else by luck. Somewhere in the band there must be
    /// a budget turned away with NotEnoughGasForDiamondCall NAMING autoAwardXP.
    ///
    /// The name matters and is not decoration: creditDisputeFee is floored too
    /// and both floors raise the same error, so a test that only looked at the
    /// error selector would go on passing after either floor was deleted.
    function testTheXpFloorRefusesByNameRatherThanByLuck() public {
        bool sawFloorRefusal;
        for (uint256 g = 400_000; g <= 560_000; g += 5_000) {
            uint256 snap = vm.snapshotState();
            Agreement a = _markedDone();
            vm.prank(client);
            (bool ok, bytes memory ret) = address(a).call{gas: g}(abi.encodeWithSignature("release()"));
            if (!ok && _refusedCall(ret) == IReputationFacet.autoAwardXP.selector) {
                sawFloorRefusal = true;
            }
            vm.revertToState(snap);
        }
        assertTrue(sawFloorRefusal, "below the floor the contract must refuse outright, not skip the XP");
    }

    /// The same for the dispute fee. Its own band: the fee floor stands
    /// EARLIER on the path than the XP floor, so budgets too small for the fee
    /// check never reach the XP one.
    function testTheDisputeFeeFloorRefusesByNameRatherThanByLuck() public {
        bool sawFloorRefusal;
        for (uint256 g = 60_000; g <= 260_000; g += 4_000) {
            uint256 snap = vm.snapshotState();
            Agreement a = _activated();
            vm.prank(client);
            a.raiseDispute();
            _claimByArbiter(a);
            vm.prank(arbiterAddr);
            ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);
            vm.warp(block.timestamp + 3 days);

            vm.prank(client);
            (bool ok, bytes memory ret) = address(diamond).call{gas: g}(
                abi.encodeWithSignature("finalizeVerdict(address)", address(a))
            );
            assertFalse(ok, "these budgets are all far below what resolving costs");
            if (_refusedCall(ret) == IArbiterRegistryFacet.creditDisputeFee.selector) {
                sawFloorRefusal = true;
            }
            vm.revertToState(snap);
        }
        assertTrue(
            sawFloorRefusal,
            "the fee floor must refuse in its own name, not leave the XP floor to answer for it"
        );
    }

    /// Same attack on the verdict path: the winner calls finalizeVerdict with
    /// a hand-picked limit, hoping creditDisputeFee falls short so the 3%
    /// stays in the pot he is about to receive.
    function testGasStarvationCannotRobTheArbiterOfTheDisputeFee() public {
        for (uint256 g = 300_000; g <= SHIPPED_FINALIZE_VERDICT_GAS; g += 20_000) {
            uint256 snap = vm.snapshotState();
            Agreement a = _activated();
            vm.prank(client);
            a.raiseDispute();
            _claimByArbiter(a);
            vm.prank(arbiterAddr);
            ArbiterRegistryFacet(address(diamond)).submitVerdict(address(a), true);
            vm.warp(block.timestamp + 3 days);

            vm.prank(client);
            (bool ok, ) = address(diamond).call{gas: g}(
                abi.encodeWithSignature("finalizeVerdict(address)", address(a))
            );

            if (ok) {
                assertGt(
                    ArbiterRegistryFacet(address(diamond)).getVaultBalance()
                        + ArbiterRegistryFacet(address(diamond)).getTreasurySlice(),
                    0,
                    "a resolution that went through must not have skipped the dispute fee"
                );
            }
            vm.revertToState(snap);
        }
    }
}
