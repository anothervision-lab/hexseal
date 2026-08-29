// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — RegistryFacet.sol
// Holds every deal, its status, and the client+executor pairs
// Lives inside the Diamond — one address forever
// ============================================================

import "./DiamondProxy.sol";

// ---------- STORAGE ----------

library RegistryStorage {
    /// @custom:storage-location erc7201:hexseal.registry.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.registry.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant REGISTRY_STORAGE_POSITION = 0xc2046377b613f781ce75bf5776eb70f650372f5239ada8a3238d951cdca15e00;

    enum AgreementStatus {
        ACTIVE,
        COMPLETED,
        REFUNDED,
        DISPUTED,
        RESOLVED
    }

    struct AgreementRecord {
        address agreement;   // address of the Agreement contract
        address client;      // the party ordering the work
        address executor;    // the party doing the work
        uint256 amount;      // deal amount in USDC (6 decimals)
        AgreementStatus status;
        uint256 createdAt;
        uint256 resolvedAt;
    }

    struct Layout {
        // agreement address → record
        mapping(address => AgreementRecord) agreements;

        // every Agreement address
        address[] allAgreements;

        // keccak(client, executor) → the active agreement
        // prevents duplicate active deals between one and the same pair
        mapping(bytes32 => address) activePartyPairs;

        // who is allowed to call register() — FactoryFacet only
        // held as the address that is authorized to make the call
        address authorizedFactory;
    }

    function store() internal pure returns (Layout storage rs) {
        bytes32 position = REGISTRY_STORAGE_POSITION;
        assembly {
            rs.slot := position
        }
    }
}

// ---------- FACET ----------

contract RegistryFacet {
    using RegistryStorage for RegistryStorage.Layout;

    // -------- EVENTS --------

    event AgreementRegistered(
        address indexed agreement,
        address indexed client,
        address indexed executor,
        uint256 amount
    );

    event AgreementStatusUpdated(
        address indexed agreement,
        RegistryStorage.AgreementStatus newStatus
    );

    event AuthorizedFactorySet(address indexed factory);

    // -------- ERRORS --------

    error OnlyAuthorizedFactory();
    error OnlyAgreementItself();
    error AgreementNotRegistered();
    error ActiveDealAlreadyExists();
    error RegistryZeroAddress();
    error AlreadyInitialized();
    error NotOwner();

    // -------- MODIFIERS --------

    modifier onlyFactory() {
        if (msg.sender != RegistryStorage.store().authorizedFactory)
            revert OnlyAuthorizedFactory();
        _;
    }

    modifier onlyAgreement(address agreement) {
        // The Agreement identifies itself as msg.sender
        if (msg.sender != agreement) revert OnlyAgreementItself();
        // And it has to be registered for real
        if (RegistryStorage.store().agreements[agreement].agreement != agreement)
            revert AgreementNotRegistered();
        _;
    }

    // -------- INIT (called once, when the Diamond is deployed) --------

    function initRegistry(address factory_) external {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        if (rs.authorizedFactory != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert RegistryZeroAddress();
        // Frontrun protection: the caller has to be the owner of the Diamond
        if (msg.sender != OwnershipLib.contractOwner()) revert NotOwner();
        rs.authorizedFactory = factory_;
        emit AuthorizedFactorySet(factory_);
    }

    // -------- WRITE --------

    /// @notice Registers a new deal. Called only by FactoryFacet, after the Agreement is deployed.
    function register(
        address agreement,
        address client,
        address executor,
        uint256 amount
    ) external onlyFactory {
        if (agreement == address(0)) revert RegistryZeroAddress();
        if (client == address(0)) revert RegistryZeroAddress();
        if (executor == address(0)) revert RegistryZeroAddress();

        RegistryStorage.Layout storage rs = RegistryStorage.store();

        bytes32 pairKey = _pairKey(client, executor);

        // One pair cannot hold two active deals at once
        if (rs.activePartyPairs[pairKey] != address(0))
            revert ActiveDealAlreadyExists();

        rs.agreements[agreement] = RegistryStorage.AgreementRecord({
            agreement: agreement,
            client: client,
            executor: executor,
            amount: amount,
            status: RegistryStorage.AgreementStatus.ACTIVE,
            createdAt: block.timestamp,
            resolvedAt: 0
        });

        rs.allAgreements.push(agreement);
        rs.activePartyPairs[pairKey] = agreement;

        emit AgreementRegistered(agreement, client, executor, amount);
    }

    /// @notice Updates the status. Called only by the Agreement contract itself.
    function updateStatus(
        address agreement,
        RegistryStorage.AgreementStatus newStatus
    ) external onlyAgreement(agreement) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        RegistryStorage.AgreementRecord storage record = rs.agreements[agreement];

        record.status = newStatus;

        // Once the deal is closed, drop it from the active pairs
        if (newStatus != RegistryStorage.AgreementStatus.ACTIVE) {
            bytes32 pairKey = _pairKey(record.client, record.executor);
            if (rs.activePartyPairs[pairKey] == agreement) {
                delete rs.activePartyPairs[pairKey];
            }
            record.resolvedAt = block.timestamp;
        }

        emit AgreementStatusUpdated(agreement, newStatus);
    }

    /// @notice Updates the Factory address (owner of the Diamond only)
    /// Needed when a new version of FactoryFacet is deployed
    function setAuthorizedFactory(address newFactory) external {
        if (msg.sender != OwnershipLib.contractOwner()) revert NotOwner();
        if (newFactory == address(0)) revert RegistryZeroAddress();
        RegistryStorage.store().authorizedFactory = newFactory;
        emit AuthorizedFactorySet(newFactory);
    }

    // -------- READ --------

    /// @notice Whether this pair has an active deal
    function hasActivePair(address client, address executor) external view returns (bool) {
        return RegistryStorage.store().activePartyPairs[_pairKey(client, executor)] != address(0);
    }

    /// @notice Address of the pair's active deal (address(0) if there is none)
    function getActivePair(address client, address executor) external view returns (address) {
        return RegistryStorage.store().activePartyPairs[_pairKey(client, executor)];
    }

    /// @notice The full record for an Agreement address
    function getRecord(address agreement) external view returns (RegistryStorage.AgreementRecord memory) {
        return RegistryStorage.store().agreements[agreement];
    }

    /// @notice Every deal of a client
    function getByClient(address client) external view returns (RegistryStorage.AgreementRecord[] memory) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        return _filter(rs, client, true);
    }

    /// @notice Every deal of an executor
    function getByExecutor(address executor) external view returns (RegistryStorage.AgreementRecord[] memory) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        return _filter(rs, executor, false);
    }

    /// @notice Every active deal (for the board)
    function getActive() external view returns (RegistryStorage.AgreementRecord[] memory) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        uint256 count;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            if (rs.agreements[rs.allAgreements[i]].status == RegistryStorage.AgreementStatus.ACTIVE) {
                count++;
            }
        }
        RegistryStorage.AgreementRecord[] memory result = new RegistryStorage.AgreementRecord[](count);
        uint256 idx;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            if (rs.agreements[rs.allAgreements[i]].status == RegistryStorage.AgreementStatus.ACTIVE) {
                result[idx++] = rs.agreements[rs.allAgreements[i]];
            }
        }
        return result;
    }

    /// @notice Every disputed deal (for the arbiters' board)
    function getDisputed() external view returns (RegistryStorage.AgreementRecord[] memory) {
        RegistryStorage.Layout storage rs = RegistryStorage.store();
        uint256 count;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            if (rs.agreements[rs.allAgreements[i]].status == RegistryStorage.AgreementStatus.DISPUTED) {
                count++;
            }
        }
        RegistryStorage.AgreementRecord[] memory result = new RegistryStorage.AgreementRecord[](count);
        uint256 idx;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            if (rs.agreements[rs.allAgreements[i]].status == RegistryStorage.AgreementStatus.DISPUTED) {
                result[idx++] = rs.agreements[rs.allAgreements[i]];
            }
        }
        return result;
    }

    /// @notice Total number of deals
    function totalAgreements() external view returns (uint256) {
        return RegistryStorage.store().allAgreements.length;
    }

    /// @notice Address of the authorized Factory
    function authorizedFactory() external view returns (address) {
        return RegistryStorage.store().authorizedFactory;
    }

    // -------- INTERNAL --------

    function _pairKey(address client, address executor) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(client, executor));
    }

    function _filter(
        RegistryStorage.Layout storage rs,
        address party,
        bool isClient
    ) internal view returns (RegistryStorage.AgreementRecord[] memory) {
        uint256 count;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            RegistryStorage.AgreementRecord storage rec = rs.agreements[rs.allAgreements[i]];
            if (isClient ? rec.client == party : rec.executor == party) count++;
        }
        RegistryStorage.AgreementRecord[] memory result = new RegistryStorage.AgreementRecord[](count);
        uint256 idx;
        for (uint256 i; i < rs.allAgreements.length; i++) {
            RegistryStorage.AgreementRecord storage rec = rs.agreements[rs.allAgreements[i]];
            if (isClient ? rec.client == party : rec.executor == party) {
                result[idx++] = rec;
            }
        }
        return result;
    }
}
