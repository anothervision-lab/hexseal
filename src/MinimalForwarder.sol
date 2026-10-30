// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract MinimalForwarder is EIP712 {
    using ECDSA for bytes32;

    struct ForwardRequest {
        address from;
        address to;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        /// The last block timestamp at which this request may still execute.
        /// `uint48` rather than `uint256` on purpose: it is the width
        /// OpenZeppelin's `ERC2771Forwarder` uses for the same field, so a
        /// signature produced for one shape is at least shaped like the other,
        /// and 2^48 seconds reaches the year 8.9 million.
        uint48 deadline;
        bytes data;
    }

    bytes32 private constant _TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
    );

    /// The maximum number of bytes copied out of the callee's return data.
    /// An untrusted `req.to` can return an arbitrarily large buffer and burn the
    /// relayer's gas on memory expansion. Legitimate answers (the address of a
    /// new Agreement, a uint256) fit into 32-64 bytes.
    uint256 private constant MAX_RETURNDATA = 4096;

    mapping(address => uint256) private _nonces;

    event Executed(address indexed from, address indexed to, bool success);

    constructor() EIP712("MinimalForwarder", "0.0.1") {}

    function getNonce(address from) public view returns (uint256) {
        return _nonces[from];
    }

    function verify(ForwardRequest calldata req, bytes calldata signature) public view returns (bool) {
        address signer = _hashTypedDataV4(
            keccak256(abi.encode(
                _TYPEHASH,
                req.from,
                req.to,
                req.value,
                req.gas,
                req.nonce,
                req.deadline,
                keccak256(req.data)
            ))
        ).recover(signature);
        return signer == req.from;
    }

    function execute(ForwardRequest calldata req, bytes calldata signature)
        external payable returns (bool success, bytes memory retdata)
    {
        // ⚠️ FIRST, AND BEFORE ecrecover, BECAUSE IT IS THE ONLY GATE THAT COSTS
        // NOTHING. A request whose window has closed is refused on one calldata
        // load and one comparison, so a stranger spraying expired requests at
        // this contract cannot buy a signature recovery with them.
        //
        // WHAT THIS CHECK IS FOR, and the nonce does NOT already do it. The
        // counter only guarantees that a signature dies once the signer's NEXT
        // gasless action lands. Somebody who signs and then walks away -- closes
        // the tab, loses the phone, changes his mind -- never takes that next
        // action, so his signature stayed executable by whoever held it for as
        // long as the forwarder lived. That is the hole this field closes, and
        // the reason the typehash changed with it: a signature made over the old
        // six-field shape does not recover to its signer here any more, which is
        // not a side effect of the fix but half of it.
        //
        // `<=` and not `<`: the deadline is the LAST second at which the request
        // is still good, not the first at which it is stale. Same reading as
        // `ERC2771Forwarder._validate` (`request.deadline >= block.timestamp`),
        // and an off-by-one the other way would refuse a request signed a
        // moment ago. Locked by testD2RequestAtItsExactDeadlineStillPasses.
        require(block.timestamp <= req.deadline, "MinimalForwarder: request expired");
        require(verify(req, signature), "MinimalForwarder: signature does not match request");
        require(_nonces[req.from] == req.nonce, "MinimalForwarder: nonce mismatch");
        // Without this check a call with req.value > msg.value is paid out of the
        // forwarder's own balance — any ETH left sitting on it can be drained by a
        // self-signed request.
        require(msg.value == req.value, "MinimalForwarder: value mismatch");

        _nonces[req.from]++;

        // EIP-2771: append original sender (req.from) to calldata so receiving
        // contracts can recover it via _msgSender() when msg.sender == trustedForwarder
        bytes memory payload = abi.encodePacked(req.data, req.from);

        // The call is made by hand in assembly with a zero-length output buffer
        // (the trailing 0, 0 of `call`). That, and not discarding a variable at
        // the Solidity level, is the actual fix: a language-level `.call(...)`
        // always drags in the compiler's standard helper, which copies the whole
        // answer into memory before any cap can be applied (confirmed by
        // disassembly — it contained an unconditional returndatacopy over the
        // full size). Here CALL copies nothing by itself, and the return data is
        // fetched by hand below, under the cap.
        address to = req.to;
        uint256 value = req.value;
        uint256 gasLimit = req.gas;
        uint256 size;
        assembly ("memory-safe") {
            success := call(gasLimit, to, value, add(payload, 0x20), mload(payload), 0, 0)
            size := returndatasize()
        }
        if (size > MAX_RETURNDATA) size = MAX_RETURNDATA;
        retdata = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(retdata, 0x20), 0, size)
        }

        emit Executed(req.from, req.to, success);
    }
}
