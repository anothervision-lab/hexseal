// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MinimalForwarder.sol";

/// Returns the last 20 bytes of the calldata — that is, the address an ERC-2771
/// forwarder appends to the tail. This is how the 2771 mechanism itself is
/// checked.
contract Echo2771 {
    address public lastSender;
    uint256 public lastValue;

    function ping() external payable returns (address) {
        address sender;
        assembly {
            sender := shr(96, calldataload(sub(calldatasize(), 20)))
        }
        lastSender = sender;
        lastValue = msg.value;
        return sender;
    }
}

/// Returns a buffer of a requested size — a parameterised return-bomb model.
/// The size varies by argument rather than by separate contracts, so that the
/// gas-differential test below compares a small return against a large one with
/// everything else held equal.
contract Bomb {
    function boom(uint256 size) external pure {
        assembly {
            return(0, size)
        }
    }
}

/// A named custom error that `Reverter` below reverts with — needed by the
/// inner-call-failure test to check that `retdata` holds precisely that error
/// and not merely a non-empty buffer.
error MockRevertError(uint256 code);

/// Always reverts with the given custom error — a separate mock callee for the
/// inner-call-failure path; it does not reuse Echo2771 or Bomb, which are there
/// for other purposes.
contract Reverter {
    function explode(uint256 code) external pure {
        revert MockRevertError(code);
    }
}

contract MinimalForwarderTest is Test {
    MinimalForwarder forwarder;
    Echo2771 echo;
    Bomb bomb;
    Reverter reverter;

    uint256 constant USER_PK = 0xA11CE;
    address user;

    bytes32 constant TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    function setUp() public {
        forwarder = new MinimalForwarder();
        echo = new Echo2771();
        bomb = new Bomb();
        reverter = new Reverter();
        user = vm.addr(USER_PK);
        vm.deal(user, 100 ether);
        vm.deal(address(this), 100 ether);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("MinimalForwarder")),
            keccak256(bytes("0.0.1")),
            block.chainid,
            address(forwarder)
        ));
    }

    function _sign(uint256 pk, MinimalForwarder.ForwardRequest memory req)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            TYPEHASH, req.from, req.to, req.value, req.gas, req.nonce, keccak256(req.data)
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _req(address to, uint256 value, bytes memory data)
        internal view returns (MinimalForwarder.ForwardRequest memory)
    {
        return MinimalForwarder.ForwardRequest({
            from:  user,
            to:    to,
            value: value,
            gas:   1_000_000,
            nonce: forwarder.getNonce(user),
            data:  data
        });
    }

    // ── verify ────────────────────────────────────────────────────────────

    function testVerifyAcceptsValidSignature() public view {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 0, abi.encodeWithSelector(Echo2771.ping.selector));
        assertTrue(forwarder.verify(req, _sign(USER_PK, req)));
    }

    function testVerifyRejectsForeignSignature() public view {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 0, abi.encodeWithSelector(Echo2771.ping.selector));
        assertFalse(forwarder.verify(req, _sign(0xB0B, req)));
    }

    function testExecuteRevertsOnForeignSignature() public {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 0, abi.encodeWithSelector(Echo2771.ping.selector));
        vm.expectRevert("MinimalForwarder: signature does not match request");
        forwarder.execute(req, _sign(0xB0B, req));
    }

    // ── ERC-2771 suffix ───────────────────────────────────────────────────

    function testAppendsOriginalSenderToCalldata() public {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 0, abi.encodeWithSelector(Echo2771.ping.selector));
        (bool ok, bytes memory ret) = forwarder.execute(req, _sign(USER_PK, req));
        assertTrue(ok);
        assertEq(echo.lastSender(), user);
        // The echo's own return value (the sender address) must reach the calling
        // forwarder untouched — this catches corruption of destination during a
        // manual copy.
        assertEq(abi.decode(ret, (address)), user);
    }

    // ── nonce / replay ────────────────────────────────────────────────────

    function testNonceIncrementsOnExecute() public {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 0, abi.encodeWithSelector(Echo2771.ping.selector));
        assertEq(forwarder.getNonce(user), 0);
        forwarder.execute(req, _sign(USER_PK, req));
        assertEq(forwarder.getNonce(user), 1);
    }

    function testReplayRejected() public {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 0, abi.encodeWithSelector(Echo2771.ping.selector));
        bytes memory sig = _sign(USER_PK, req);
        forwarder.execute(req, sig);
        vm.expectRevert("MinimalForwarder: nonce mismatch");
        forwarder.execute(req, sig);
    }

    // ── msg.value must equal req.value ────────────────────────────────────

    function testExecuteRevertsWhenMsgValueBelowReqValue() public {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 1 ether, abi.encodeWithSelector(Echo2771.ping.selector));
        vm.expectRevert("MinimalForwarder: value mismatch");
        forwarder.execute{value: 0}(req, _sign(USER_PK, req));
    }

    function testExecuteRevertsWhenMsgValueAboveReqValue() public {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 0, abi.encodeWithSelector(Echo2771.ping.selector));
        vm.expectRevert("MinimalForwarder: value mismatch");
        forwarder.execute{value: 1 ether}(req, _sign(USER_PK, req));
    }

    function testExecuteForwardsMatchingValue() public {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 1 ether, abi.encodeWithSelector(Echo2771.ping.selector));
        (bool ok,) = forwarder.execute{value: 1 ether}(req, _sign(USER_PK, req));
        assertTrue(ok);
        assertEq(echo.lastValue(), 1 ether);
    }

    /// The heart of it: without a msg.value check, ETH left sitting on the
    /// forwarder can be drained by a self-signed request with value > 0 and
    /// msg.value == 0.
    function testCannotDrainForwarderBalance() public {
        vm.deal(address(forwarder), 5 ether);
        MinimalForwarder.ForwardRequest memory req =
            _req(address(echo), 5 ether, abi.encodeWithSelector(Echo2771.ping.selector));
        vm.expectRevert("MinimalForwarder: value mismatch");
        forwarder.execute{value: 0}(req, _sign(USER_PK, req));
        assertEq(address(forwarder).balance, 5 ether);
    }

    // ── return bomb ───────────────────────────────────────────────────────

    function testReturndataIsCapped() public {
        MinimalForwarder.ForwardRequest memory req =
            _req(address(bomb), 0, abi.encodeWithSelector(Bomb.boom.selector, uint256(200_000)));
        (bool ok, bytes memory ret) = forwarder.execute(req, _sign(USER_PK, req));
        assertTrue(ok);
        // Exact equality, not "<=": otherwise a corrupted destination (a zeroed
        // length, say) would pass the check too.
        assertEq(ret.length, 4096, "returndata not capped to expected size");
    }

    /// The gas measurement. Before the fix, a `.call(...)` written at the
    /// Solidity level drags in the compiler's standard helper, which copies the
    /// callee's ENTIRE response into the forwarder's memory before there is any
    /// chance to cap it (visible in the disassembly) — that copy grows
    /// quadratically with the size of the response and burns relayer gas beyond
    /// the cap. After the fix (a raw CALL in assembly with a zero-length output
    /// buffer) the forwarder copies nothing of its own before the cap, so the
    /// gas difference between a large and a small return is explained purely by
    /// the bomb contract's own execution (memory expansion in ITS frame for
    /// req.gas), not by anything the forwarder does.
    function testReturndataCopyGasDoesNotScaleWithBombSize() public {
        uint256 smallSize = 32;
        uint256 largeSize = 200_000;

        // A dry run before the measurements: it warms the _nonces[user] slot (the
        // same sender as in both measurements) and the bomb account. Otherwise the
        // first measurement would pay for a cold nonce write (~21.6k) and a cold
        // access to bomb (~2.5k) and the second would not, and that difference
        // would settle into the delta as a systematic error having nothing to do
        // with the size of the response.
        MinimalForwarder.ForwardRequest memory reqWarm =
            _req(address(bomb), 0, abi.encodeWithSelector(Bomb.boom.selector, smallSize));
        forwarder.execute(reqWarm, _sign(USER_PK, reqWarm));

        MinimalForwarder.ForwardRequest memory reqSmall =
            _req(address(bomb), 0, abi.encodeWithSelector(Bomb.boom.selector, smallSize));
        bytes memory sigSmall = _sign(USER_PK, reqSmall);
        uint256 gasBeforeSmall = gasleft();
        forwarder.execute(reqSmall, sigSmall);
        uint256 gasUsedSmall = gasBeforeSmall - gasleft();

        MinimalForwarder.ForwardRequest memory reqLarge =
            _req(address(bomb), 0, abi.encodeWithSelector(Bomb.boom.selector, largeSize));
        bytes memory sigLarge = _sign(USER_PK, reqLarge);
        uint256 gasBeforeLarge = gasleft();
        forwarder.execute(reqLarge, sigLarge);
        uint256 gasUsedLarge = gasBeforeLarge - gasleft();

        // The threshold between "the delta is explained by the bomb's execution
        // alone" (after the fix) and "the delta also contains a needless full copy
        // of the response inside the forwarder" (before the fix, many times
        // larger).
        assertLt(
            gasUsedLarge - gasUsedSmall,
            140_000,
            "returndata copy gas scales with bomb size"
        );
    }

    // ── inner call failure ────────────────────────────────────────────────

    /// Helper: drops the leading 4 bytes (the selector) of a buffer so the
    /// remaining ABI payload of a custom error can be decoded with abi.decode.
    function _dropSelector(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }

    /// A CHARACTERISATION test: `execute()` deliberately does NOT revert when the
    /// nested call fails — it burns the nonce, emits `Executed(from, to, false)`
    /// and puts the callee's revert data into `retdata`. The relay API depends on
    /// that behaviour: it simulates `execute()` precisely in order to tell
    /// "execute returned normally but success == false" apart from a genuine
    /// success, and it parses `retdata` to show the user the name of the specific
    /// error rather than a generic "Call failed". Should anybody ever want to
    /// "fix" execute() so that it reverts on a failed nested call, that would
    /// break the simulation on the client. This test pins the present behaviour
    /// so such a change cannot slip through unnoticed.
    function testExecuteDoesNotRevertOnInnerCallFailure() public {
        uint256 code = 1337;
        MinimalForwarder.ForwardRequest memory req =
            _req(address(reverter), 0, abi.encodeWithSelector(Reverter.explode.selector, code));
        bytes memory sig = _sign(USER_PK, req);

        uint256 nonceBefore = forwarder.getNonce(user);

        vm.expectEmit(true, true, false, true);
        emit MinimalForwarder.Executed(user, address(reverter), false);

        (bool ok, bytes memory retdata) = forwarder.execute(req, sig);

        assertFalse(ok, "execute() must report inner-call failure via success == false, not revert");
        assertEq(forwarder.getNonce(user), nonceBefore + 1, "nonce must be consumed even when inner call fails");

        // retdata must be PRECISELY the revert data of Reverter.explode(code) and
        // not merely a non-empty buffer — compared byte for byte against the
        // expected ABI encoding of the custom error...
        assertEq(retdata, abi.encodeWithSelector(MockRevertError.selector, code), "retdata does not match callee's revert data");

        // ...and additionally the selector and the payload are decoded separately.
        bytes4 selector;
        assembly {
            selector := mload(add(retdata, 32))
        }
        assertEq(selector, MockRevertError.selector, "retdata selector mismatch");
        uint256 decodedCode = abi.decode(_dropSelector(retdata), (uint256));
        assertEq(decodedCode, code, "retdata payload mismatch");
    }
}
