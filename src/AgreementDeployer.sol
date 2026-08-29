// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — AgreementDeployer.sol
// A standalone contract (not a Diamond facet) that creates new
// Agreement instances as EIP-1167 minimal proxies.
//
// It used to carry type(Agreement).creationCode and perform a
// CREATE — that cost ~4.4M gas per deal and inflated the deployer
// itself to 23,849 bytes. Agreement is now deployed once as an
// implementation, and each deal creates a 45-byte clone.
//
// The `import Agreement.sol` is kept on purpose: tests and scripts
// need it transitively, and creationCode does not reach the bytecode
// until type(Agreement).creationCode or new Agreement() is written.
// ============================================================

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./Agreement.sol";

interface IAgreementDeployer {
    function deploy(
        address client,
        address executor,
        address arbiter,
        uint256 amount,
        uint256 deadlineDays,
        string  calldata terms,
        address diamond,
        address usdc,
        address trustedForwarder,
        address factory
    ) external returns (address);
}

contract AgreementDeployer is IAgreementDeployer {
    address public immutable authorizedCaller;
    address public immutable implementation;

    constructor(address authorizedCaller_, address implementation_) {
        require(authorizedCaller_ != address(0), "AgreementDeployer: zero caller");
        require(implementation_   != address(0), "AgreementDeployer: zero implementation");
        // Mandatory, not decorative. Clones.clone() does not check that the
        // implementation has any code, and in the EVM a call to a code-less
        // address returns SUCCESS: initialize() would "work", deploy() would
        // return an address, the client would fund an empty shell, and any
        // outsider could later initialise that shell in their own favour.
        require(implementation_.code.length > 0, "AgreementDeployer: implementation has no code");
        authorizedCaller = authorizedCaller_;
        implementation   = implementation_;
    }

    function deploy(
        address client,
        address executor,
        address arbiter,
        uint256 amount,
        uint256 deadlineDays,
        string  calldata terms,
        address diamond,
        address usdc,
        address trustedForwarder,
        address factory
    ) external returns (address addr) {
        require(msg.sender == authorizedCaller, "AgreementDeployer: unauthorized");
        // clone() and initialize() happen in one transaction — nothing can wedge
        // itself in between, so an uninitialised clone cannot be hijacked.
        addr = Clones.clone(implementation);
        Agreement(addr).initialize(
            client, executor, arbiter,
            amount, deadlineDays, terms,
            diamond, usdc, trustedForwarder, factory
        );
    }
}
