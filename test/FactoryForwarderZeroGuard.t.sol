// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./BoardsFixture.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";

// ============================================================
// HEXSEAL — FactoryForwarderZeroGuard.t.sol
//
// The lock for `setTrustedForwarder(address(0))`, and for the reason it is
// refused rather than just for the fact that it is.
//
// WHAT WAS WRONG. `initFactory` has always rejected a zero forwarder
// (`FactoryZeroAddress`), and `setAgreementDeployer`, the neighbour two lines
// below the setter, checks its own argument. `setTrustedForwarder` checked
// nothing. The contract had taken a decision about this field and its setter
// had never carried it.
//
// ⚠️ WHY A FORWARDER IS SIGNED IN HERE INSTEAD OF THE FACET BEING CALLED
// DIRECTLY. A test that pranks the facet proves nothing about ERC-2771: with
// no forwarder configured `_msgSender()` falls through to `msg.sender` and the
// broken and the fixed code behave identically. That is exactly how the
// `fundDispute` bug (fix `d172064`, 31 July 2026) survived a green suite. So
// the cost of a zero is MEASURED below, through a real MinimalForwarder, a
// real signature and a third address paying the gas — and it is measured on
// the state the guard now prevents, reached by writing the storage slot
// directly, because the setter will no longer take us there.
//
// WHAT THE MEASUREMENT SHOWS, AND WHY IT IS THE BAD KIND OF BREAKAGE.
// `applyForJob` has no money in it and no counterparty check, so a relayed
// call under a zero forwarder does not revert — it SUCCEEDS and writes the
// forwarder's address down as the applicant. Nobody is told. The money doors
// fail loudly instead (`NotClient`), which is worse for the person and better
// for the diagnosis; this file locks the silent half, because the silent half
// is the one no report would ever contain.
//
// ⚠️ WHAT NO TEST HERE CAN UNDO. The forwarder is baked into an Agreement at
// birth and an EIP-1167 clone is nailed to its implementation for life
// (src/Agreement.sol: `_initTrustedForwarder` is called once from the
// initializer and there is no setter for anybody). Deals created while the
// field held zero would never get the repair. That is the whole reason the
// guard is on the door rather than in a runbook.
// ============================================================

contract FactoryForwarderZeroGuardTest is BoardsFixture {

    uint256 constant CLIENT_PK   = 0xC11E17;
    uint256 constant APPLICANT_PK = 0xA9911CA7;

    /// A third address: not a party, not the forwarder. In production this is
    /// the relayer, and it is nobody in the deal.
    address constant RELAYER = address(0x9999);

    /// `trustedForwarder` is the fourth member of FactoryStorage.Layout —
    /// usdc(0), feeRecipient(1), regionFee(2, a mapping owning its own slot),
    /// trustedForwarder(3). The same offset BoardsFixture documents at the top
    /// of its own slot table, and it is asserted below rather than trusted.
    uint256 constant SLOT_TRUSTED_FORWARDER = 3;

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    // ══════════════════════════════════════════════════════════════════════
    // THE APPOINTED LOCK
    // ══════════════════════════════════════════════════════════════════════

    /// ⚠️ THIS IS THE TEST THE ZERO CHECK EXISTS FOR. Remove
    /// `if (newForwarder == address(0)) revert FactoryZeroAddress();` from
    /// `FactoryFacet.setTrustedForwarder` and this one names it.
    ///
    /// Two assertions, and the second earns its place. `expectRevert` proves the
    /// CALL failed; it says nothing about the field. Here the two happen to
    /// coincide, because a revert unwinds the write in the same call — and that
    /// is worth asserting rather than assuming, because it stops being true the
    /// moment the write moves behind a low-level call whose failure is
    /// swallowed, which is how `deployAndFund` already talks to a clone
    /// (`agreementAddress.call(...)`). The claim that matters is the one about
    /// state: the forwarder the diamond had is the forwarder it still has.
    function test_TheSetterRefusesZeroAndLeavesTheFieldWhereItWas() public {
        address before = FactoryFacet(address(diamond)).getTrustedForwarder();
        assertTrue(before != address(0), "precondition: the fixture starts with a forwarder set");

        vm.prank(owner);
        vm.expectRevert(FactoryFacet.FactoryZeroAddress.selector);
        FactoryFacet(address(diamond)).setTrustedForwarder(address(0));

        assertEq(
            FactoryFacet(address(diamond)).getTrustedForwarder(),
            before,
            "the setter refused the zero and wrote it anyway"
        );
    }

    /// The other direction, so the guard cannot be satisfied by a setter that
    /// refuses everything. A real address still goes through and is readable
    /// back.
    function test_ANonZeroForwarderStillGoesThrough() public {
        MinimalForwarder fwd = new MinimalForwarder();

        vm.prank(owner);
        FactoryFacet(address(diamond)).setTrustedForwarder(address(fwd));

        assertEq(
            FactoryFacet(address(diamond)).getTrustedForwarder(),
            address(fwd),
            "a legitimate forwarder was refused"
        );
    }

    /// The decision the setter was missing, stated as a comparison rather than
    /// as a paragraph: `initFactory`, `setTrustedForwarder` and the neighbour
    /// `setAgreementDeployer` must now all refuse a zero, with the SAME error.
    /// Before this change the middle one was the only one that did not, which
    /// is the whole argument for the guard — the contract had already decided
    /// about this field and one door had not been told.
    ///
    /// `initFactory` is reached by zeroing `usdc` (member 0 of the layout, the
    /// flag it uses for "already initialised"). Its guards run in order —
    /// AlreadyInitialized, NotOwner, then the five zero checks — so this is the
    /// only way to ask it the question at all on a fixture that is already up.
    function test_InitAndBothSettersTakeTheSameDecisionAboutZero() public {
        vm.store(address(diamond), FactoryStorage.FACTORY_STORAGE_POSITION, bytes32(0));
        assertEq(
            FactoryFacet(address(diamond)).getUsdc(),
            address(0),
            "the usdc offset in FactoryStorage.Layout has moved - this test is asking the wrong slot"
        );

        vm.expectRevert(FactoryFacet.FactoryZeroAddress.selector);
        FactoryFacet(address(diamond)).initFactory(
            address(usdc), feeRecipient, address(0), address(diamond), address(0xDEED)
        );

        vm.expectRevert(FactoryFacet.FactoryZeroAddress.selector);
        FactoryFacet(address(diamond)).setTrustedForwarder(address(0));

        // The neighbour, which had the check all along and is the reason the
        // omission in `setTrustedForwarder` reads as an oversight rather than a
        // decision. BoardsFixture does not mount its selector -- the fixture
        // carries a hand-picked subset, not the live set -- so it is mounted
        // here, onto the SAME FactoryFacet the fixture already routes to, read
        // off the loupe rather than guessed at.
        address factoryImpl = IDiamondLoupe(address(diamond))
            .facetAddress(FactoryFacet.setTrustedForwarder.selector);
        assertTrue(factoryImpl != address(0), "the fixture does not route setTrustedForwarder");

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = FactoryFacet.setAgreementDeployer.selector;
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut(factoryImpl, IDiamondCut.FacetCutAction.Add, sels);
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        vm.expectRevert(FactoryFacet.FactoryZeroAddress.selector);
        FactoryFacet(address(diamond)).setAgreementDeployer(address(0));
    }

    // ══════════════════════════════════════════════════════════════════════
    // WHAT THE GUARD IS FOR — measured through a real forwarder
    // ══════════════════════════════════════════════════════════════════════

    /// The control. With a real forwarder configured, a relayed `applyForJob`
    /// records the PERSON who signed. Without this half the test below would
    /// pass on a diamond where the relayed road never worked at all.
    function test_Control_RelayedApplyRecordsTheSigner() public {
        MinimalForwarder fwd = new MinimalForwarder();
        vm.prank(owner);
        FactoryFacet(address(diamond)).setTrustedForwarder(address(fwd));

        address applicant = vm.addr(APPLICANT_PK);
        uint256 jobId = _postAJob();

        _relayApply(fwd, APPLICANT_PK, jobId);

        address[] memory applicants = JobBoardFacet(address(diamond)).getApplicants(jobId);
        assertEq(applicants.length, 1, "the relayed application did not land");
        assertEq(applicants[0], applicant, "the applicant recorded is not the person who signed");
    }

    /// ⚠️ THE COST OF A ZERO, MEASURED RATHER THAN ARGUED. The slot is written
    /// directly, because the setter now refuses to take us here — which is the
    /// point. The same relayed call then SUCCEEDS and writes the FORWARDER's
    /// address down as the applicant.
    ///
    /// Nothing reverts. Nothing is emitted about it. The person who signed is
    /// simply not on the list, and the only address that is belongs to a
    /// contract. This is the failure mode the guard removes, and it is the one
    /// that would never appear in an incident report, because there would be no
    /// incident — only a person whose application vanished.
    function test_AZeroForwarderSilentlyRecordsTheRelayerAsTheApplicant() public {
        MinimalForwarder fwd = new MinimalForwarder();
        vm.prank(owner);
        FactoryFacet(address(diamond)).setTrustedForwarder(address(fwd));

        uint256 jobId = _postAJob();
        address applicant = vm.addr(APPLICANT_PK);

        // The state the guard now prevents, reached the only way still open.
        _forceForwarderTo(address(0));
        assertEq(
            FactoryFacet(address(diamond)).getTrustedForwarder(),
            address(0),
            "the slot write did not land - the offset in FactoryStorage.Layout has moved"
        );

        _relayApply(fwd, APPLICANT_PK, jobId);

        address[] memory applicants = JobBoardFacet(address(diamond)).getApplicants(jobId);
        assertEq(applicants.length, 1, "the call did not even go through - this failure is meant to be SILENT");
        assertEq(
            applicants[0],
            address(fwd),
            "expected the damage: with a zero forwarder the applicant recorded is the forwarder itself"
        );
        assertTrue(applicants[0] != applicant, "the person who signed must NOT be the one recorded here");
    }

    // ══════════════════════════════════════════════════════════════════════
    // RIG
    // ══════════════════════════════════════════════════════════════════════

    function _postAJob() internal returns (uint256 jobId) {
        vm.startPrank(client);
        usdc.approve(address(diamond), type(uint256).max);
        jobId = JobBoardFacet(address(diamond)).mintJob("t", "d", AMOUNT, DEADLINE, TERMS, REGION);
        vm.stopPrank();
    }

    /// Sign a ForwardRequest as `pk` and have RELAYER — a third address, neither
    /// party nor forwarder — pay for it, exactly as in production.
    function _relayApply(MinimalForwarder fwd, uint256 pk, uint256 jobId) internal {
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  vm.addr(pk),
            to:    address(diamond),
            value: 0,
            gas:   1_000_000,
            nonce: fwd.getNonce(vm.addr(pk)),
            data:  abi.encodeWithSelector(JobBoardFacet.applyForJob.selector, jobId)
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
                address(fwd)
            )),
            structHash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vm.prank(RELAYER);
        (bool ok, bytes memory ret) = fwd.execute(req, abi.encodePacked(r, s, v));
        assertTrue(ok, string.concat("the forwarded applyForJob reverted: ", vm.toString(ret)));
    }

    /// Writes `trustedForwarder` straight into the diamond's storage. Only for
    /// reaching the state the guard forbids — no production path can do this.
    function _forceForwarderTo(address forwarder) internal {
        vm.store(
            address(diamond),
            bytes32(uint256(FactoryStorage.FACTORY_STORAGE_POSITION) + SLOT_TRUSTED_FORWARDER),
            bytes32(uint256(uint160(forwarder)))
        );
    }
}
