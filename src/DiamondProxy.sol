// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — DiamondProxy.sol
// EIP-2535 Diamond Standard
// OZ v5 · Base (Sepolia today, mainnet ahead) · Foundry
// ============================================================

// ---------- INTERFACES ----------

interface IDiamondCut {
    enum FacetCutAction { Add, Replace, Remove }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    function diamondCut(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external;

    event DiamondCut(FacetCut[] _diamondCut, address _init, bytes _calldata);
}

interface IDiamondLoupe {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    function facets() external view returns (Facet[] memory facets_);
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory facetFunctionSelectors_);
    function facetAddresses() external view returns (address[] memory facetAddresses_);
    function facetAddress(bytes4 _functionSelector) external view returns (address facetAddress_);
}

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

// ---------- STORAGE ----------

library DiamondStorage {
    /// @custom:storage-location erc7201:hexseal.diamond.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.diamond.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant DIAMOND_STORAGE_POSITION = 0x178642b411f9f4783b21ef338f3e96db6c1272d763f0b7500ec93464dafb8600;

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition; // position in facetFunctionSelectors array
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition; // position of facetAddress in facetAddresses array
    }

    struct Layout {
        // selector → facet info
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        // facet → selectors
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        // all facet addresses
        address[] facetAddresses;
        // ERC165
        mapping(bytes4 => bool) supportedInterfaces;
        // owner (multisig)
        address contractOwner;
        // two-step ownership transfer
        address pendingOwner;
    }

    function store() internal pure returns (Layout storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }
}

// ---------- GLOBAL REENTRANCY GUARD ----------
// A single guard shared by every facet — it prevents cross-facet reentrancy.
// Every facet uses DiamondGuard instead of a per-facet guard of its own.

library DiamondGuard {
    /// @custom:storage-location erc7201:hexseal.diamond.reentrancy
    /// keccak256(abi.encode(uint256(keccak256("hexseal.diamond.reentrancy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant GUARD_POSITION = 0xb7972581c5756b955ddfcaf36802d7a349c326f2d1a13edfdb5743b59d909700;
    uint256 constant NOT_ENTERED = 1;
    uint256 constant ENTERED = 2;

    function status() internal view returns (uint256 s) {
        bytes32 p = GUARD_POSITION;
        assembly { s := sload(p) }
    }

    function setStatus(uint256 s) internal {
        bytes32 p = GUARD_POSITION;
        assembly { sstore(p, s) }
    }
}

// ---------- OWNERSHIP ----------

library OwnershipLib {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setContractOwner(address _newOwner) internal {
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = _newOwner;
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    function contractOwner() internal view returns (address owner_) {
        owner_ = DiamondStorage.store().contractOwner;
    }

    function enforceIsContractOwner() internal view {
        require(msg.sender == DiamondStorage.store().contractOwner, "Diamond: not owner");
    }
}

// ---------- DIAMOND CUT LIBRARY ----------

library DiamondCutLib {
    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);

    bytes32 constant CLEAR_ADDRESS_MASK = bytes32(uint256(0xffffffffffffffffffffffff));
    bytes32 constant CLEAR_SELECTOR_MASK = bytes32(uint256(0xffffffff << 224));

    function diamondCut(
        IDiamondCut.FacetCut[] memory _diamondCut,
        address _init,
        bytes memory _calldata
    ) internal {
        for (uint256 facetIndex; facetIndex < _diamondCut.length; facetIndex++) {
            IDiamondCut.FacetCutAction action = _diamondCut[facetIndex].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                removeFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else {
                revert("Diamond: incorrect FacetCutAction");
            }
        }
        emit DiamondCut(_diamondCut, _init, _calldata);
        initializeDiamondCut(_init, _calldata);
    }

    function addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "Diamond: no selectors");
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        require(_facetAddress != address(0), "Diamond: zero facet address");
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            require(oldFacetAddress == address(0), "Diamond: selector exists");
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    function replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "Diamond: no selectors");
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        require(_facetAddress != address(0), "Diamond: zero facet address");
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            require(oldFacetAddress != _facetAddress, "Diamond: same facet");
            removeFunction(ds, oldFacetAddress, selector);
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    function removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        require(_functionSelectors.length > 0, "Diamond: no selectors");
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        require(_facetAddress == address(0), "Diamond: remove needs zero address");
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            removeFunction(ds, oldFacetAddress, selector);
        }
    }

    function addFacet(DiamondStorage.Layout storage ds, address _facetAddress) internal {
        enforceHasContractCode(_facetAddress, "Diamond: no code");
        ds.facetFunctionSelectors[_facetAddress].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(_facetAddress);
    }

    function addFunction(
        DiamondStorage.Layout storage ds,
        bytes4 _selector,
        uint96 _selectorPosition,
        address _facetAddress
    ) internal {
        ds.selectorToFacetAndPosition[_selector].functionSelectorPosition = _selectorPosition;
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.push(_selector);
        ds.selectorToFacetAndPosition[_selector].facetAddress = _facetAddress;
    }

    function removeFunction(
        DiamondStorage.Layout storage ds,
        address _facetAddress,
        bytes4 _selector
    ) internal {
        require(_facetAddress != address(0), "Diamond: selector not found");
        require(_facetAddress != address(this), "Diamond: immutable function");
        uint256 selectorPosition = ds.selectorToFacetAndPosition[_selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[_facetAddress].functionSelectors.length - 1;
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[_facetAddress].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[_facetAddress].functionSelectors[selectorPosition] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[_selector];
        if (lastSelectorPosition == 0) {
            uint256 facetAddressPosition = ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacetAddress;
                ds.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
        }
    }

    function initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) return;
        enforceHasContractCode(_init, "Diamond: init no code");
        (bool success, bytes memory errData) = _init.delegatecall(_calldata);
        if (!success) {
            if (errData.length > 0) {
                assembly {
                    revert(add(32, errData), mload(errData))
                }
            } else {
                revert("Diamond: init reverted");
            }
        }
    }

    function enforceHasContractCode(address _contract, string memory _errorMessage) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        require(contractSize > 0, _errorMessage);
    }
}

// ---------- DIAMOND PROXY ----------

contract DiamondProxy {
    constructor(address _owner, IDiamondCut.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) {
        OwnershipLib.setContractOwner(_owner);
        DiamondCutLib.diamondCut(_diamondCut, _init, _calldata);

        DiamondStorage.Layout storage ds = DiamondStorage.store();

        // ERC165
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        // The Diamond mints soulbound receipt NFTs through JobReceiptFacet, so it
        // declares ERC-721 and ERC721Metadata here rather than through a separate
        // supportsInterface implementation inside that facet — otherwise selector
        // 0x01ffc9a7 would belong to two facets at once and the loupe interfaces
        // would stop being recognised.
        ds.supportedInterfaces[0x80ac58cd] = true; // ERC-721
        ds.supportedInterfaces[0x5b5e139f] = true; // ERC-721 Metadata
    }

    fallback() external payable {
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: function not found");
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable { revert("Diamond: ETH not accepted"); }
}

// ---------- DIAMOND CUT FACET ----------
// A built-in facet — administration of the Diamond itself

contract DiamondCutFacet is IDiamondCut {
    function diamondCut(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external override {
        OwnershipLib.enforceIsContractOwner();
        DiamondCutLib.diamondCut(_diamondCut, _init, _calldata);
    }
}

// ---------- DIAMOND LOUPE FACET ----------
// The reader — which facets exist and which selectors they own

contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
    function facets() external view override returns (Facet[] memory facets_) {
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        uint256 numFacets = ds.facetAddresses.length;
        facets_ = new Facet[](numFacets);
        for (uint256 i; i < numFacets; i++) {
            address facetAddress_ = ds.facetAddresses[i];
            facets_[i].facetAddress = facetAddress_;
            facets_[i].functionSelectors = ds.facetFunctionSelectors[facetAddress_].functionSelectors;
        }
    }

    function facetFunctionSelectors(address _facet) external view override returns (bytes4[] memory facetFunctionSelectors_) {
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        facetFunctionSelectors_ = ds.facetFunctionSelectors[_facet].functionSelectors;
    }

    function facetAddresses() external view override returns (address[] memory facetAddresses_) {
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        facetAddresses_ = ds.facetAddresses;
    }

    function facetAddress(bytes4 _functionSelector) external view override returns (address facetAddress_) {
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        facetAddress_ = ds.selectorToFacetAndPosition[_functionSelector].facetAddress;
    }

    function supportsInterface(bytes4 _interfaceId) external view override returns (bool) {
        DiamondStorage.Layout storage ds = DiamondStorage.store();
        return ds.supportedInterfaces[_interfaceId];
    }
}

// ---------- OWNERSHIP FACET ----------

contract OwnershipFacet {
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function transferOwnership(address _newOwner) external {
        OwnershipLib.enforceIsContractOwner();
        require(_newOwner != address(0), "Diamond: zero owner");
        DiamondStorage.store().pendingOwner = _newOwner;
        emit OwnershipTransferStarted(OwnershipLib.contractOwner(), _newOwner);
    }

    function acceptOwnership() external {
        address pending = DiamondStorage.store().pendingOwner;
        require(msg.sender == pending, "Diamond: not pending owner");
        DiamondStorage.store().pendingOwner = address(0);
        OwnershipLib.setContractOwner(pending);
    }

    function owner() external view returns (address owner_) {
        owner_ = OwnershipLib.contractOwner();
    }

    function pendingOwner() external view returns (address) {
        return DiamondStorage.store().pendingOwner;
    }
}
