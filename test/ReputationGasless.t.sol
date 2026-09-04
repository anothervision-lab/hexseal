// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ReputationFacet, ReputationStorage} from "../src/facets/ReputationFacet.sol";
import {RegistryStorage} from "../src/RegistryFacet.sol";
import {FactoryStorage} from "../src/FactoryFacet.sol";
import {MinimalForwarder} from "../src/MinimalForwarder.sol";

// ============================================================
// HEXSEAL — ReputationGasless.t.sol
//
// OPEN-ITEMS item 23.2. `claimXP` is the one function in ReputationFacet that a
// person calls with their own wallet, and until 1 September 2026 it read raw
// `msg.sender` while the facet implemented no `_msgSender()` at all. Relayed,
// `msg.sender` is the MinimalForwarder's address, so `NotParty` refused every
// gasless claim — the same shape as incident C1 (`fundDispute`, fix `d172064`).
//
// ⚠️ WHY THIS FILE EXISTS AT ALL, AND WHY IT CALLS A FORWARDER. Every other
// test that touches claimXP calls the facet directly, under `vm.prank`. In that
// environment `trustedForwarder` is unset, `_msgSender()` falls through to
// `msg.sender`, and swapping one for the other changes nothing — all of them
// stay green on the broken code. A lock for this bug HAS to sign a real
// ForwardRequest and let a real forwarder make the call.
// ============================================================

/// The minimum an Agreement has to answer for ReputationFacet to read it.
contract MockAgreementView {
    uint8   public status;
    uint256 public amount;
    address public client;
    address public executor;
    bool    public clientWonDispute;

    constructor(uint8 st, uint256 amt, address cli, address exc) {
        status = st;
        amount = amt;
        client = cli;
        executor = exc;
    }
}

contract ReputationGaslessTest is Test {
    ReputationFacet facet;
    MockAgreementView agmt;

    uint256 constant CLIENT_PK = 0xC11E17;
    address client;
    address executor = address(0xE7EC);
    address relayer  = address(0x9999); // a third address: not a party, not the forwarder

    uint8   constant STATUS_COMPLETED = 3;
    uint256 constant DEAL_AMOUNT = 20_000_000; // 20 USDC — above MIN_WIN_AMOUNT

    bytes32 constant FWD_TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    function setUp() public {
        client = vm.addr(CLIENT_PK);
        facet = new ReputationFacet();
        agmt = new MockAgreementView(STATUS_COMPLETED, DEAL_AMOUNT, client, executor);
        _registerAgreement(address(agmt));
    }

    // -------- STORAGE FIXTURES --------
    //
    // The facet is deployed on its own, with no diamond behind it, exactly as in
    // ArbiterChatKey.t.sol. Both namespaces it reads therefore have to be written
    // straight into its own storage.

    /// `RegistryStorage.Layout.agreements` is the FIRST member of the layout, so
    /// the mapping's base slot is the namespace position itself, and the record's
    /// `agreement` field is the first word of the value struct.
    function _registerAgreement(address agreement) internal {
        bytes32 slot = keccak256(
            abi.encode(agreement, RegistryStorage.REGISTRY_STORAGE_POSITION)
        );
        vm.store(address(facet), slot, bytes32(uint256(uint160(agreement))));
        // Not taken on trust: if the layout ever drifts, this must fail here with
        // a readable reason rather than write into a neighbouring field and leave
        // one guessing why the claim "did not work".
        assertEq(
            address(uint160(uint256(vm.load(address(facet), slot)))),
            agreement,
            "the agreements offset in RegistryStorage.Layout has moved"
        );
    }

    /// `trustedForwarder` sits 3 slots from the base of FactoryStorage.Layout —
    /// usdc(0), feeRecipient(1), regionFee(2, a mapping owning its own slot),
    /// trustedForwarder(3). The same offset BoardsFixture and ArbiterChatKey.t.sol
    /// already assert.
    function _setTrustedForwarder(address forwarder) internal {
        bytes32 slot = bytes32(uint256(FactoryStorage.FACTORY_STORAGE_POSITION) + 3);
        vm.store(address(facet), slot, bytes32(uint256(uint160(forwarder))));
        assertEq(
            address(uint160(uint256(vm.load(address(facet), slot)))),
            forwarder,
            "the trustedForwarder offset in FactoryStorage.Layout has moved"
        );
    }

    function _signFwd(MinimalForwarder fwd, uint256 pk, MinimalForwarder.ForwardRequest memory req)
        internal view returns (bytes memory)
    {
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
        return abi.encodePacked(r, s, v);
    }

    // -------- THE MEASUREMENT --------

    /// `claimXP` called through a real MinimalForwarder must credit the PERSON who
    /// signed the ForwardRequest — not the forwarder address that physically made
    /// the call. `execute()` is sent by a THIRD address, neither party nor
    /// forwarder, exactly as in production: the relayer pays the gas and is
    /// nobody in the deal.
    ///
    /// Three assertions, and all three are load-bearing:
    ///   * the call must SUCCEED — on raw `msg.sender` the sender is the
    ///     forwarder, `NotParty` fires, and the human never gets their XP;
    ///   * the XP must land on the client;
    ///   * the forwarder's own balance must stay zero. Without that last one the
    ///     test would still pass in a world where `_msgSender()` returned
    ///     anything at all, as long as somebody's XP moved.
    function test_ClaimXP_ThroughRealForwarder_AwardsTheHumanNotTheForwarder() public {
        MinimalForwarder fwd = new MinimalForwarder();
        _setTrustedForwarder(address(fwd));

        assertEq(facet.getXP(client), 0, "precondition: the client starts at zero XP");

        bytes memory data = abi.encodeWithSelector(ReputationFacet.claimXP.selector, address(agmt));
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  client,
            to:    address(facet),
            value: 0,
            gas:   500_000,
            nonce: fwd.getNonce(client),
            data:  data
        });
        bytes memory sig = _signFwd(fwd, CLIENT_PK, req);

        vm.prank(relayer);
        (bool ok, bytes memory ret) = fwd.execute(req, sig);
        assertTrue(ok, string.concat("forwarded claimXP failed: ", vm.toString(ret)));

        assertGt(facet.getXP(client), 0, "XP must be awarded to the signer, not lost");
        assertEq(
            facet.getXP(address(fwd)),
            0,
            "XP leaked to the forwarder address instead of the person"
        );
        assertTrue(facet.hasClaimed(address(agmt), client), "the claim must be recorded for the human");
    }

    /// The forwarder must not become a party by standing in the middle. Signed by
    /// the client, so the claim succeeds — but nothing about the forwarder may be
    /// written down anywhere, including the claim flag.
    function test_ClaimXP_ThroughRealForwarder_DoesNotMakeTheForwarderAParty() public {
        MinimalForwarder fwd = new MinimalForwarder();
        _setTrustedForwarder(address(fwd));

        bytes memory data = abi.encodeWithSelector(ReputationFacet.claimXP.selector, address(agmt));
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  client,
            to:    address(facet),
            value: 0,
            gas:   500_000,
            nonce: fwd.getNonce(client),
            data:  data
        });
        vm.prank(relayer);
        (bool ok, ) = fwd.execute(req, _signFwd(fwd, CLIENT_PK, req));
        assertTrue(ok, "forwarded claimXP failed");

        // The executor has not claimed — a claim credited to the forwarder would
        // have had to take one of the two slots, and there are only two.
        assertFalse(
            facet.hasClaimed(address(agmt), executor),
            "the executor's slot was consumed by somebody who is not the executor"
        );
        assertEq(facet.getXP(relayer), 0, "the relayer must never be credited either");
    }

    /// The direct road must keep working unchanged. A `_msgSender()` that read the
    /// calldata tail unconditionally would break this one while leaving the
    /// forwarded test above green.
    function test_ClaimXP_DirectCall_StillCreditsTheCaller() public {
        // No forwarder set at all — the production shape of a wallet transaction.
        vm.prank(client);
        facet.claimXP(address(agmt));
        assertGt(facet.getXP(client), 0, "a direct claim must still credit the caller");
    }

    /// And with a forwarder configured, a direct call from the wallet still takes
    /// the fallback branch rather than reading a tail that is not there.
    function test_ClaimXP_DirectCall_WithForwarderConfigured_StillCreditsTheCaller() public {
        MinimalForwarder fwd = new MinimalForwarder();
        _setTrustedForwarder(address(fwd));

        vm.prank(executor);
        facet.claimXP(address(agmt));
        assertGt(facet.getXP(executor), 0, "a direct claim must not be mistaken for a relayed one");
        assertEq(facet.getXP(address(fwd)), 0, "nothing may be credited to the forwarder");
    }

    /// The two callbacks keep RAW msg.sender on purpose, and this is the reason.
    /// A forwarded call that appends an Agreement's address to the calldata tail
    /// must NOT be able to pass itself off as that Agreement.
    function test_AutoAwardXP_ThroughForwarder_CannotImpersonateTheAgreement() public {
        MinimalForwarder fwd = new MinimalForwarder();
        _setTrustedForwarder(address(fwd));

        uint256 attackerPk = 0xBAD;
        address attacker = vm.addr(attackerPk);

        bytes memory data = abi.encodeWithSelector(ReputationFacet.autoAwardXP.selector, address(agmt));
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  attacker,
            to:    address(facet),
            value: 0,
            gas:   500_000,
            nonce: fwd.getNonce(attacker),
            data:  data
        });
        vm.prank(relayer);
        (bool ok, ) = fwd.execute(req, _signFwd(fwd, attackerPk, req));
        assertFalse(ok, "autoAwardXP must refuse a caller that is not the Agreement itself");
        assertEq(facet.getXP(client), 0, "no XP may be awarded on an impersonated callback");
        assertEq(facet.getXP(executor), 0, "no XP may be awarded on an impersonated callback");
    }
}
