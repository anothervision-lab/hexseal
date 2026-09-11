// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Agreement.sol";
import "../src/AgreementDeployer.sol";
import "../src/MinimalForwarder.sol";

contract AgreementCloneTest is Test {
    Agreement         impl;
    AgreementDeployer deployer;

    address constant CALLER    = address(0xCA11E4);
    address constant CLIENT    = address(0xC11E17);
    address constant EXECUTOR  = address(0xE8EC);
    address constant DIAMOND   = address(0xD1A);
    address constant USDC      = address(0x05DC);
    address constant FORWARDER = address(0xF04D);

    function setUp() public {
        impl     = new Agreement();
        deployer = new AgreementDeployer(CALLER, address(impl));
    }

    function _deploy() internal returns (address) {
        vm.prank(CALLER);
        return deployer.deploy(
            CLIENT, EXECUTOR, address(0),
            1_000_000, 7, "terms",
            DIAMOND, USDC, FORWARDER, DIAMOND
        );
    }

    function testCloneCarriesAllInitParams() public {
        Agreement a = Agreement(_deploy());

        assertEq(a.client(),       CLIENT,    "client");
        assertEq(a.executor(),     EXECUTOR,  "executor");
        assertEq(a.arbiter(),      address(0), "arbiter starts unset");
        assertEq(a.amount(),       1_000_000, "amount");
        assertEq(a.deadlineDays(), 7,         "deadlineDays");
        assertEq(a.terms(),        "terms",   "terms");
        assertEq(a.diamond(),      DIAMOND,   "diamond");
        assertEq(a.usdc(),         USDC,      "usdc");
        assertEq(a.factory(),      DIAMOND,   "factory");
        assertEq(a.trustedForwarder(), FORWARDER, "trustedForwarder");
        assertEq(uint8(a.status()), uint8(Agreement.Status.CREATED), "status");
        assertEq(a.name(),   "Hexseal Deal", "name");
        assertEq(a.symbol(), "HSEAL",        "symbol");
    }

    /// A clone is 45 bytes of EIP-1167, not a copy of a twenty-kilobyte Agreement.
    function testCloneIsMinimalProxy() public {
        assertEq(_deploy().code.length, 45, "clone is not a 45-byte EIP-1167 proxy");
    }

    /// A second call on an already initialised clone.
    function testInitializeRevertsOnSecondCall() public {
        Agreement a = Agreement(_deploy());
        vm.expectRevert(Agreement.AlreadyInitialized.selector);
        a.initialize(
            address(0xBAD), address(0xBAD2), address(0),
            1, 1, "hijack",
            DIAMOND, USDC, FORWARDER, DIAMOND
        );
    }

    /// A stranger cannot re-initialise somebody else's deal — the guard does not
    /// depend on who is calling.
    function testStrangerCannotReinitialize() public {
        Agreement a = Agreement(_deploy());
        vm.prank(address(0xDEAD));
        vm.expectRevert(Agreement.AlreadyInitialized.selector);
        a.initialize(
            address(0xBAD), address(0xBAD2), address(0),
            1, 1, "hijack",
            DIAMOND, USDC, FORWARDER, DIAMOND
        );
    }

    /// The implementation contract itself is locked in its constructor: it has
    /// storage of its own, and without the lock a stranger would become its
    /// "client".
    function testImplementationIsLocked() public {
        vm.expectRevert(Agreement.AlreadyInitialized.selector);
        impl.initialize(
            address(0xBAD), address(0xBAD2), address(0),
            1, 1, "hijack",
            DIAMOND, USDC, FORWARDER, DIAMOND
        );
    }

    /// An implementation with no code is rejected in the deployer's constructor.
    /// Otherwise Clones.clone() would create a proxy pointing at nothing,
    /// initialize() would report success (a call to a codeless address succeeds
    /// in the EVM), and the deal would be an empty shell open to takeover.
    function testDeployerRejectsCodelessImplementation() public {
        vm.expectRevert("AgreementDeployer: implementation has no code");
        new AgreementDeployer(CALLER, address(0xC0DE1E55));
    }

    /// _initReentrancyGuard() has no observable effect: the modifier only
    /// compares against ENTERED, so a clone with _status == 0 behaves the same.
    /// Which means deleting that line would not fail a single test. The slot is
    /// read directly — otherwise the guard against a silent breakage would
    /// itself be introduced silently.
    function testReentrancyGuardIsInitialized() public {
        address clone = _deploy();
        assertEq(
            uint256(vm.load(clone, bytes32(uint256(4)))),
            1,
            "reentrancy guard left uninitialized"
        );
    }

    /// Prints the actual cost of creating a deal (the number feeds reports and
    /// the treasury-model arithmetic) and at the same time guards against a
    /// regression: the threshold is set well above the measured 278 355, but an
    /// order of magnitude below the former ~4 400 000. If somebody brings back a
    /// full CREATE, it fails.
    function testCloneDeployStaysCheap() public {
        uint256 before = gasleft();
        _deploy();
        uint256 used = before - gasleft();
        emit log_named_uint("gas: clone + initialize", used);
        assertLt(used, 400_000, "deal creation is no longer clone-cheap");
    }
}

// ---------- MOCK USDC ----------

contract MockUSDCClone {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
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

/// The one thing the clone asks its diamond for on the top-up path: the rate.
/// A diamond that does not answer makes proposeExtra revert FeeUnavailable, so
/// the gasless fixture below needs a diamond with code on it before it can
/// tell a refusal for EMPTY TERMS apart from a refusal for a mute diamond.
contract MockFeeDiamondClone {
    function getFeeBps() external pure returns (uint256) { return 500; }
}

/// The gasless path end to end: a real MinimalForwarder → an Agreement clone.
///
/// WHY A SEPARATE TEST. With the move to EIP-1167 the trustedForwarder moved
/// out of the implementation code (immutable) and into the clone's storage,
/// while ERC-2771 rests on the 20-byte sender suffix the forwarder appends to
/// the end of the calldata reaching the implementation through the proxy's
/// delegatecall. That rests in turn on the EIP-1167 runtime (`36 3d 3d 37` —
/// a calldatacopy of the whole calldata), and no test checked it: in every
/// diamond setup trustedForwarder is address(0xDEAD), and MinimalForwarder's
/// own suite hits the Echo2771 mock rather than a clone. The closest thing
/// that existed was testCloneCarriesAllInitParams, and that only checks the
/// forwarder address that was written down, not that _msgSender() works.
///
/// This breaks silently: on a move to Clones.cloneWithImmutableArgs, say,
/// which appends its own arguments to the end of that same calldata and would
/// collide with exactly this convention — _msgSender() would start returning
/// the tail of those arguments instead of the signer's address, and every
/// action by a party to the deal would be rejected as "not the client".
contract AgreementCloneGaslessTest is Test {
    MinimalForwarder     forwarder;
    Agreement            impl;
    AgreementDeployer    deployer;
    MockUSDCClone        usdc;
    MockFeeDiamondClone  feeDiamond;

    address constant CALLER  = address(0xCA11E4);
    uint256 constant AMOUNT  = 1_000_000;

    uint256 constant CLIENT_PK   = 0xC11;
    uint256 constant EXECUTOR_PK = 0xE8E;
    uint256 constant STRANGER_PK = 0xBAD;
    address client;
    address executor;
    address stranger;

    Agreement agr;

    bytes32 constant TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    function setUp() public {
        forwarder = new MinimalForwarder();
        usdc      = new MockUSDCClone();
        impl      = new Agreement();
        deployer  = new AgreementDeployer(CALLER, address(impl));
        // A diamond with code on it, so the top-up path can get an answer about
        // the rate. Nothing else in this fixture asks the diamond anything.
        feeDiamond = new MockFeeDiamondClone();

        client   = vm.addr(CLIENT_PK);
        executor = vm.addr(EXECUTOR_PK);
        stranger = vm.addr(STRANGER_PK);

        vm.prank(CALLER);
        agr = Agreement(deployer.deploy(
            client, executor, address(0),
            AMOUNT, 7, "terms",
            address(feeDiamond), address(usdc), address(forwarder), address(feeDiamond)
        ));

        usdc.mint(client, AMOUNT);
        vm.prank(client);
        usdc.approve(address(agr), AMOUNT);
    }

    function _sign(uint256 pk, MinimalForwarder.ForwardRequest memory req)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            TYPEHASH, req.from, req.to, req.value, req.gas, req.nonce, keccak256(req.data)
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
        return abi.encodePacked(r, s, v);
    }

    /// execute() does not revert when the inner call fails — it returns
    /// (false, revertData). So success has to be read from the return value
    /// rather than inferred from the absence of a revert.
    function _relay(uint256 pk, bytes memory data)
        internal returns (bool success, bytes memory retdata)
    {
        address from = vm.addr(pk);
        MinimalForwarder.ForwardRequest memory req = MinimalForwarder.ForwardRequest({
            from:  from,
            to:    address(agr),
            value: 0,
            gas:   1_000_000,
            nonce: forwarder.getNonce(from),
            data:  data
        });
        return forwarder.execute(req, _sign(pk, req));
    }

    /// fund() is the most telling check: it both compares _msgSender() against
    /// client and pulls USDC from precisely that address. Had the suffix not
    /// arrived, _msgSender() would have returned the forwarder's address and the
    /// call would have failed on NotClient.
    function testGaslessFundThroughForwarderReachesClone() public {
        (bool ok, ) = _relay(CLIENT_PK, abi.encodeWithSelector(Agreement.fund.selector));
        assertTrue(ok, "forwarded fund() failed inside the clone");

        assertEq(agr.fundedAt(), block.timestamp, "agr not funded");
        assertEq(usdc.balanceOf(address(agr)), AMOUNT, "USDC pulled from the wrong account");
        assertEq(usdc.balanceOf(client), 0, "client was not the payer");
        assertEq(agr.ownerOf(1), client,   "client NFT");
        assertEq(agr.ownerOf(2), executor, "executor NFT");
        assertEq(uint8(agr.status()), uint8(Agreement.Status.FUNDED), "status");
    }

    /// Second party, second nonce: the suffix is recognised for more than just
    /// the address that deployed the deal.
    function testGaslessActivateThroughForwarderReachesClone() public {
        (bool funded, ) = _relay(CLIENT_PK, abi.encodeWithSelector(Agreement.fund.selector));
        assertTrue(funded, "setup: fund failed");

        (bool ok, ) = _relay(EXECUTOR_PK, abi.encodeWithSelector(Agreement.activate.selector));
        assertTrue(ok, "forwarded activate() failed inside the clone");

        assertEq(agr.activatedAt(), block.timestamp, "agr not activated");
        assertEq(uint8(agr.status()), uint8(Agreement.Status.ACTIVE), "status");
    }

    /// Negative control: without it the test above would pass in a world where
    /// _msgSender() returns anything at all, as long as it happens to equal
    /// client. A stranger signing through the same forwarder must be refused.
    function testGaslessCallFromStrangerIsRejectedByTheClone() public {
        (bool ok, bytes memory retdata) =
            _relay(STRANGER_PK, abi.encodeWithSelector(Agreement.fund.selector));

        assertFalse(ok, "clone accepted a forwarded call from a non-party");
        assertEq(bytes4(retdata), Agreement.NotClient.selector, "wrong revert reason");
        assertEq(agr.fundedAt(), 0, "agr must stay unfunded");
    }

    /// A direct call bypassing the forwarder still works when made by the party
    /// itself — the ERC-2771 check must not have broken the ordinary wallet path
    /// (which is also the client's fallback when the relayer is unreachable).
    function testDirectCallStillWorksAlongsideTheForwarder() public {
        vm.prank(client);
        agr.fund();
        assertEq(agr.fundedAt(), block.timestamp, "direct fund() broken");
    }

    // ============================================================
    //  A TOP-UP CARRIES WORDS OF ITS OWN, ON THE GASLESS PATH TOO
    //  (decision 76)
    // ============================================================
    //
    // ⚠️ WHY THIS IS NOT COVERED BY THE DIRECT-CALL TESTS IN Extras.t.sol.
    // Everything a person actually does here arrives through the relayer, so
    // the refusal that matters is the one seen at the end of a real
    // MinimalForwarder. A test that calls the clone directly cannot tell that
    // apart from a refusal that only happens to fire for wallets — that is the
    // exact shape of the fundDispute bug of 31 July 2026 (d172064), where a
    // check read msg.sender and the relayed call never worked once while every
    // direct test stayed green.
    //
    // The forwarder does not revert when the inner call fails, so both halves
    // are read off `execute`'s return value, not off the absence of a revert.

    /// Bring the deal to ACTIVE the way a person would: both steps relayed.
    function _relayedActiveDeal() internal {
        (bool funded, ) = _relay(CLIENT_PK, abi.encodeWithSelector(Agreement.fund.selector));
        assertTrue(funded, "setup: relayed fund failed");
        (bool active, ) = _relay(EXECUTOR_PK, abi.encodeWithSelector(Agreement.activate.selector));
        assertTrue(active, "setup: relayed activate failed");
    }

    /// Give the client enough USDC and enough allowance for a top-up of
    /// `amount` plus the 5% the client pays on top.
    function _fundClientForTopUp(uint256 amount) internal returns (uint256 total) {
        total = amount + agr.quoteExtraFee(amount);
        usdc.mint(client, total);
        vm.prank(client);
        usdc.approve(address(agr), total);
    }

    function testGaslessProposeExtraWithEmptyTermsIsRefused() public {
        _relayedActiveDeal();
        uint256 total = _fundClientForTopUp(500_000);

        uint256 clientBefore = usdc.balanceOf(client);
        uint256 agrBefore    = usdc.balanceOf(address(agr));

        (bool ok, bytes memory retdata) = _relay(
            CLIENT_PK,
            abi.encodeWithSelector(Agreement.proposeExtra.selector, uint256(500_000), "")
        );

        assertFalse(ok, "the clone accepted a relayed top-up with no words at all");
        assertEq(bytes4(retdata), Agreement.EmptyTerms.selector, "wrong revert reason");

        // The refusal is free of consequence on this path too.
        assertEq(agr.nextExtraId(), 0, "nextExtraId moved on a refused relayed top-up");
        assertEq(agr.pendingExtrasTotal(), 0, "pendingExtrasTotal moved");
        assertEq(agr.pendingExtraFeeTotal(), 0, "pendingExtraFeeTotal moved");
        assertEq(usdc.balanceOf(client), clientBefore, "the client paid for a refused top-up");
        assertEq(usdc.balanceOf(address(agr)), agrBefore, "the clone took money for a refused top-up");
        // The allowance is untouched, so nothing was pulled and silently sent back.
        assertEq(usdc.allowance(client, address(agr)), total, "allowance was spent");
    }

    /// The positive control the refusal above needs. Without it that test
    /// passes in a world where the relayed top-up never works at all — which
    /// is precisely the world the fundDispute bug lived in.
    function testGaslessProposeExtraWithRealTermsGoesThrough() public {
        _relayedActiveDeal();
        uint256 total = _fundClientForTopUp(500_000);

        (bool ok, ) = _relay(
            CLIENT_PK,
            abi.encodeWithSelector(Agreement.proposeExtra.selector, uint256(500_000), "one more screen")
        );

        assertTrue(ok, "a relayed top-up WITH terms was refused");
        assertEq(agr.nextExtraId(), 1, "the top-up was not recorded");
        assertEq(agr.pendingExtrasTotal(), 500_000, "pendingExtrasTotal");
        (uint256 amount, string memory terms, ) = agr.extras(0);
        assertEq(amount, 500_000, "amount");
        assertEq(terms, "one more screen", "terms did not survive the forwarder");
        // The money moved from the SIGNER, not from the forwarder: the whole
        // point of _msgSender() on this path.
        assertEq(usdc.balanceOf(address(agr)), AMOUNT + total, "the clone did not receive the top-up");
        assertEq(usdc.balanceOf(client), 0, "the client was not the payer");
        assertEq(usdc.balanceOf(address(forwarder)), 0, "the forwarder paid, which is the bug");
    }

    /// ⚠️ PLACEMENT, WHICH THE OTHER TESTS CANNOT SEE.
    ///
    /// "Nothing was written and no token moved" is true of ANY revert — the
    /// EVM rolls the whole call back — so asserting it proves the function
    /// refused, not that the refusal came early. This proves the early part:
    /// against a diamond that will not name the rate, an empty top-up must
    /// still come back EmptyTerms. If the check sat one line lower, the same
    /// call would die on FeeUnavailable instead.
    ///
    /// The second half is the control that makes the first half mean
    /// something: with real terms, the very same clone DOES die on
    /// FeeUnavailable. So the diamond really is mute, and the first assertion
    /// is not passing because the fee read happened to succeed.
    function testEmptyTermsIsDecidedBeforeTheDiamondIsAskedForTheRate() public {
        address muteDiamond = address(0xD1A); // no code on it at all
        vm.prank(CALLER);
        Agreement mute = Agreement(deployer.deploy(
            client, executor, address(0),
            AMOUNT, 7, "terms",
            muteDiamond, address(usdc), address(forwarder), muteDiamond
        ));

        usdc.mint(client, AMOUNT * 4);
        vm.startPrank(client);
        usdc.approve(address(mute), type(uint256).max);
        mute.fund();
        vm.stopPrank();
        vm.prank(executor);
        mute.activate();

        vm.prank(client);
        vm.expectRevert(Agreement.EmptyTerms.selector);
        mute.proposeExtra(500_000, "");

        vm.prank(client);
        vm.expectRevert(Agreement.FeeUnavailable.selector);
        mute.proposeExtra(500_000, "one more screen");
    }
}
