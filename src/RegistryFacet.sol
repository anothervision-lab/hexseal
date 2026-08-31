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

    /// The executor handed the work in, and a clock is now running against the
    /// client. Emitted BY THE DIAMOND, on the diamond's own address, and that
    /// is the entire reason it exists.
    ///
    /// `markDone()` writes only to the clone and emits `MarkedDone` there,
    /// while the one chain observer the web client is allowed to keep is
    /// pinned to this address. So the transition that starts
    /// AUTO_APPROVE_WINDOW -- the one where the client's silence hands the
    /// whole escrow to the executor two days later -- was the only major
    /// transition in a deal's life the diamond could not see at all.
    ///
    /// WHY NOT `AgreementStatusUpdated(agreement, ACTIVE)`, which would have
    /// needed no new selector and no cut. Two reasons, and the second is
    /// decisive:
    ///
    ///   * the enum above has no member for this, so ACTIVE would have to be
    ///     read as "handed in" by inference rather than by statement, and the
    ///     day something else emitted ACTIVE the meaning would break in
    ///     silence;
    ///   * `Agreement.syncRegistry()` is callable BY ANYONE and already pushes
    ///     exactly ACTIVE for any deal that is not disputed or finished. A
    ///     stranger could therefore ring the client's "your work has arrived"
    ///     bell at will, on a deal where nothing had happened. That is not a
    ///     hypothetical shape -- the selector is mounted and the function takes
    ///     no arguments.
    ///
    /// Carries client and executor for the same reason `AgreementRegistered`
    /// does: an indexed party is a filter the node can apply, so a reader
    /// interested in one person does not have to hold a map of every deal to
    /// find out whether this one is theirs.
    event WorkHandedIn(
        address indexed agreement,
        address indexed client,
        address indexed executor
    );

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

    /// @notice The Agreement announces that its executor has handed the work in.
    ///
    /// THE CALLER IS THE KEY. No `agreement` argument, so there is none to pass
    /// wrongly and none for a stranger to point at somebody else's deal: the
    /// only address this function can name is the one that called it, and it
    /// must already be in the registry. Same shape, and the same argument, as
    /// `ArbiterRegistryFacet.creditDisputeFee`.
    ///
    /// WRITES NOTHING, on purpose. The clone holds `_markedDoneAt` and is the
    /// authority on it; a copy here would be a second number free to disagree
    /// with the first, and it would cost a cold SSTORE on every hand-in to
    /// create that disagreement. The status stays ACTIVE because the deal IS
    /// still active -- a handed-in deal can still be disputed, released, or
    /// left to auto-approve -- and moving it out of ACTIVE would drop the pair
    /// from `activePartyPairs` and stamp `resolvedAt` on a deal that has not
    /// resolved.
    ///
    /// A second call therefore changes no state and costs the caller gas.
    /// `markDone()` refuses a second run (`AlreadyMarkedDone`), so a second
    /// call cannot come from an honest clone at all; from a dishonest one it
    /// buys a duplicate log entry and nothing else.
    function notifyWorkHandedIn() external {
        RegistryStorage.AgreementRecord storage record =
            RegistryStorage.store().agreements[msg.sender];
        if (record.agreement != msg.sender) revert AgreementNotRegistered();

        emit WorkHandedIn(msg.sender, record.client, record.executor);
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
