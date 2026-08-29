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
    MinimalForwarder  forwarder;
    Agreement         impl;
    AgreementDeployer deployer;
    MockUSDCClone     usdc;

    address constant CALLER  = address(0xCA11E4);
    address constant DIAMOND = address(0xD1A);
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

        client   = vm.addr(CLIENT_PK);
        executor = vm.addr(EXECUTOR_PK);
        stranger = vm.addr(STRANGER_PK);

        vm.prank(CALLER);
        agr = Agreement(deployer.deploy(
            client, executor, address(0),
            AMOUNT, 7, "terms",
            DIAMOND, address(usdc), address(forwarder), DIAMOND
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
}
