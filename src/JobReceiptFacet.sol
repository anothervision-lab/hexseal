// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — JobReceiptFacet.sol
//
// Soulbound NFT receipt issued to the client when a job is posted.
// Minted automatically from JobBoardFacet through an internal Diamond call.
//
// Uses the same namespaced storage slot as OfferNFTFacet
// (keccak256("hexseal.offernft.storage")) — the data is preserved.
//
// OfferNFTFacet has been cut out of the Diamond; this facet replaces it.
// ============================================================

import "./DiamondProxy.sol";
import "./SVGRenderer.sol";

// ─── Storage (same slot as OfferNFTFacet — data preserved) ───────────────────

library ReceiptStorage {
    /// @custom:storage-location erc7201:hexseal.offernft.storage
    /// keccak256(abi.encode(uint256(keccak256("hexseal.offernft.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant POSITION = 0xcda203cf548fb5f65947761da4867a0c96d965f3755581c496cf785aac114900;

    struct JobReceiptData {
        address client;
        string  title;
        uint256 amount;
        uint256 deadlineDays;
        uint8   region;
        uint256 createdAt;
    }

    struct Layout {
        uint256 reentrancyStatus;
        uint256 nextTokenId;
        mapping(uint256 => address)  _offers_executor;   // deprecated
        mapping(address => uint256[]) _executorOffers;   // deprecated
        mapping(uint256 => address[]) _offerHires;       // deprecated
        mapping(address => uint256)  balances;
        mapping(uint256 => address)  owners;
        address _deprecated_receiptNFT;
        mapping(uint256 => bool)           isJobReceipt;
        mapping(uint256 => JobReceiptData) jobReceiptData;
        mapping(uint256 => bool)           jobReceiptMinted;
        address svgRenderer;
        mapping(uint256 => uint256) jobIdToTokenId;    // jobId → tokenId (set on mint)
        mapping(uint256 => bool)    jobIdToTokenIdSet; // sentinel to distinguish tokenId=0 from "not set"
    }

    function store() internal pure returns (Layout storage l) {
        bytes32 pos = POSITION;
        assembly { l.slot := pos }
    }
}

// ─── JobReceiptFacet ──────────────────────────────────────────────────────────

contract JobReceiptFacet {

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event JobReceiptMinted(uint256 indexed tokenId, uint256 indexed jobId, address indexed client);
    event JobReceiptBurned(uint256 indexed tokenId, uint256 indexed jobId, address indexed client);
    event SvgRendererUpdated(address indexed renderer);

    modifier onlyOwner() {
        if (msg.sender != OwnershipLib.contractOwner()) revert("Not owner");
        _;
    }

    // ─── ERC-721 Metadata ─────────────────────────────────────────────────────

    function name()   external pure returns (string memory) { return "Hexseal Receipt"; }
    function symbol() external pure returns (string memory) { return "HSEALR"; }

    // ─── ERC-721 Views ────────────────────────────────────────────────────────

    function balanceOf(address owner) external view returns (uint256) {
        require(owner != address(0), "ERC721: zero address");
        return ReceiptStorage.store().balances[owner];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = ReceiptStorage.store().owners[tokenId];
        require(owner != address(0), "ERC721: nonexistent token");
        return owner;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        ReceiptStorage.Layout storage s = ReceiptStorage.store();
        require(s.owners[tokenId] != address(0), "ERC721: nonexistent token");
        require(s.isJobReceipt[tokenId], "Not a receipt token");

        address renderer = s.svgRenderer;
        require(renderer != address(0), "SVGRenderer not set");

        ReceiptStorage.JobReceiptData storage r = s.jobReceiptData[tokenId];
        return ISVGRenderer(renderer).renderReceipt(ISVGRenderer.ReceiptParams({
            tokenId:      tokenId,
            client:       r.client,
            title:        r.title,
            amount:       r.amount,
            deadlineDays: r.deadlineDays,
            region:       r.region,
            createdAt:    r.createdAt
        }));
    }

    // ─── Soulbound — every transfer/approve is blocked ───────────────────────

    function transferFrom(address, address, uint256) external pure {
        revert("Soulbound: non-transferable");
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert("Soulbound: non-transferable");
    }

    // solhint-disable-next-line
    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert("Soulbound: non-transferable");
    }

    function approve(address, uint256) external pure {
        revert("Soulbound: non-transferable");
    }

    function setApprovalForAll(address, bool) external pure {
        revert("Soulbound: non-transferable");
    }

    function getApproved(uint256) external pure returns (address) { return address(0); }
    function isApprovedForAll(address, address) external pure returns (bool) { return false; }

    // ─── Admin: SVGRenderer ───────────────────────────────────────────────────

    function setSvgRenderer(address renderer) external onlyOwner {
        require(renderer != address(0), "Zero address");
        ReceiptStorage.store().svgRenderer = renderer;
        emit SvgRendererUpdated(renderer);
    }

    function getSvgRenderer() external view returns (address) {
        return ReceiptStorage.store().svgRenderer;
    }

    // ─── Core: Mint Receipt ───────────────────────────────────────────────────

    function mintJobReceipt(
        address to,
        uint256 jobId,
        uint256 amount,
        uint256 deadlineDays,
        uint8   region,
        string calldata title
    ) external returns (uint256 tokenId) {
        require(msg.sender == address(this), "Only Diamond");

        ReceiptStorage.Layout storage s = ReceiptStorage.store();
        if (s.jobReceiptMinted[jobId]) return type(uint256).max;

        s.jobReceiptMinted[jobId] = true;
        tokenId = s.nextTokenId++;

        s.isJobReceipt[tokenId] = true;
        s.jobReceiptData[tokenId] = ReceiptStorage.JobReceiptData({
            client:       to,
            title:        title,
            amount:       amount,
            deadlineDays: deadlineDays,
            region:       region,
            createdAt:    block.timestamp
        });

        s.owners[tokenId] = to;
        s.balances[to]++;
        s.jobIdToTokenId[jobId]    = tokenId;
        s.jobIdToTokenIdSet[jobId] = true;

        emit Transfer(address(0), to, tokenId);
        emit JobReceiptMinted(tokenId, jobId, to);
    }

    function burnJobReceipt(uint256 jobId) external returns (bool burned) {
        require(msg.sender == address(this), "Only Diamond");
        ReceiptStorage.Layout storage s = ReceiptStorage.store();
        if (!s.jobIdToTokenIdSet[jobId]) return false;
        uint256 tokenId = s.jobIdToTokenId[jobId];
        address owner = s.owners[tokenId];
        if (owner == address(0)) return false; // already burned

        s.owners[tokenId] = address(0);
        s.balances[owner]--;

        emit Transfer(owner, address(0), tokenId);
        emit JobReceiptBurned(tokenId, jobId, owner);
        return true;
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function getJobReceiptData(uint256 tokenId) external view returns (ReceiptStorage.JobReceiptData memory) {
        ReceiptStorage.Layout storage s = ReceiptStorage.store();
        require(s.isJobReceipt[tokenId], "Not a receipt token");
        return s.jobReceiptData[tokenId];
    }

    function isJobReceiptToken(uint256 tokenId) external view returns (bool) {
        return ReceiptStorage.store().isJobReceipt[tokenId];
    }

    function isJobReceiptBurned(uint256 tokenId) external view returns (bool) {
        ReceiptStorage.Layout storage s = ReceiptStorage.store();
        return s.isJobReceipt[tokenId] && s.owners[tokenId] == address(0);
    }

    function getTokenIdByJobId(uint256 jobId) external view returns (uint256 tokenId, bool exists) {
        ReceiptStorage.Layout storage s = ReceiptStorage.store();
        return (s.jobIdToTokenId[jobId], s.jobIdToTokenIdSet[jobId]);
    }

    function getReceiptTotalSupply() external view returns (uint256) {
        return ReceiptStorage.store().nextTokenId;
    }
}
