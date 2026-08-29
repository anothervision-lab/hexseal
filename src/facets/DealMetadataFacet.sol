// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Base64.sol";

// ============================================================
// DealMetadataFacet — on-chain SVG metadata for Agreement NFTs
//
// Agreement.sol calls getDealTokenURI() through the Diamond.
// That keeps Agreement.sol small, which matters because Agreement is
// deployed once as the implementation every EIP-1167 clone delegates to,
// so its runtime bytecode has to fit the 24,576-byte contract size limit
// on its own.
//
// Status codes (uint8) = Agreement.Status enum:
//   0=CREATED 1=FUNDED 2=ACTIVE 3=COMPLETED 4=DISPUTED 5=RESOLVED 6=REFUNDED
// ============================================================

contract DealMetadataFacet {

    function getDealTokenURI(
        address deal,
        uint8   /* tokenId */,
        uint8   statusCode,
        address client_,
        address executor_,
        uint256 amount_,
        uint256 deadlineDays_,
        bytes32 termsHash_
    ) external pure returns (string memory) {
        string memory img = string(abi.encodePacked(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(_buildSVG(deal, statusCode, client_, executor_, amount_, deadlineDays_)))
        ));
        return string(abi.encodePacked(
            'data:application/json;utf8,{"name":"HSEAL Deal ',
            _shortAddr(deal),
            '","description":"Escrow: ',
            _shortAddr(client_), ' -> ', _shortAddr(executor_),
            '","image":"', img,
            '","attributes":[', _buildAttrs(statusCode, amount_, deadlineDays_, client_, executor_, termsHash_), ']}'
        ));
    }

    // -------- ATTRS --------

    function _buildAttrs(
        uint8   statusCode,
        uint256 amount_,
        uint256 deadlineDays_,
        address client_,
        address executor_,
        bytes32 termsHash_
    ) private pure returns (string memory) {
        return string(abi.encodePacked(
            '{"trait_type":"Status","value":"',        _statusStr(statusCode),       '"},'
            '{"trait_type":"Amount USDC","value":"',    _uint2str(amount_ / 1e6),    '"},'
            '{"trait_type":"Deadline Days","value":"',  _uint2str(deadlineDays_),     '"},'
            '{"trait_type":"Token","value":"',          statusCode == 1 ? "Executor" : "Client", '"},'
            '{"trait_type":"Client","value":"',         _toHex(client_),              '"},'
            '{"trait_type":"Executor","value":"',       _toHex(executor_),            '"},'
            '{"trait_type":"Terms Hash","value":"0x',   _bytes32HexShort(termsHash_), '"}'
        ));
    }

    // -------- SVG --------

    function _buildSVG(
        address deal,
        uint8   statusCode,
        address client_,
        address executor_,
        uint256 amount_,
        uint256 deadlineDays_
    ) private pure returns (string memory) {
        string memory col = _statusColor(statusCode);
        string memory st  = _statusStr(statusCode);
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="520" viewBox="0 0 400 520">',
            '<rect width="400" height="520" fill="#0a0a0a"/>',
            '<rect x="0" y="0" width="400" height="4" fill="', col, '"/>',
            '<text x="200" y="38" text-anchor="middle" font-family="monospace" font-size="16" fill="#ffffff" font-weight="bold" letter-spacing="2">SIGNATURE 404</text>',
            '<text x="200" y="54" text-anchor="middle" font-family="monospace" font-size="9" fill="#444444" letter-spacing="3">DEAL AGREEMENT</text>',
            '<text x="32" y="70" font-family="monospace" font-size="10" fill="#333333">', _shortAddr(deal), '</text>',
            '<line x1="32" y1="78" x2="368" y2="78" stroke="#1a1a1a" stroke-width="1" stroke-dasharray="5,4"/>',
            _buildSVGStatus(col, st),
            _buildSVGData(client_, executor_, amount_, deadlineDays_),
            _buildSVGFooter()
        ));
    }

    function _buildSVGStatus(string memory col, string memory st) private pure returns (string memory) {
        return string(abi.encodePacked(
            '<rect x="32" y="90" width="336" height="36" rx="4" fill="', col, '" fill-opacity="0.12"/>',
            '<rect x="32" y="90" width="3" height="36" rx="1" fill="', col, '"/>',
            '<text x="46" y="113" font-family="monospace" font-size="14" fill="', col, '" font-weight="bold">', st, '</text>',
            '<line x1="32" y1="140" x2="368" y2="140" stroke="#1e1e1e" stroke-width="1" stroke-dasharray="5,4"/>'
        ));
    }

    function _buildSVGData(
        address client_,
        address executor_,
        uint256 amount_,
        uint256 deadlineDays_
    ) private pure returns (string memory) {
        return string(abi.encodePacked(
            '<text x="32"  y="162" font-family="monospace" font-size="9" fill="#555" letter-spacing="1">AMOUNT</text>',
            '<text x="220" y="162" font-family="monospace" font-size="9" fill="#555" letter-spacing="1">DEADLINE</text>',
            '<text x="32"  y="182" font-family="monospace" font-size="14" fill="#fff" font-weight="bold">', _formatUSDC(amount_), '</text>',
            '<text x="220" y="182" font-family="monospace" font-size="14" fill="#fff" font-weight="bold">', _uint2str(deadlineDays_), ' days</text>',
            '<line x1="32" y1="200" x2="368" y2="200" stroke="#1e1e1e" stroke-width="1" stroke-dasharray="5,4"/>',
            '<text x="32" y="222" font-family="monospace" font-size="9" fill="#555" letter-spacing="1">CLIENT</text>',
            '<text x="32" y="240" font-family="monospace" font-size="12" fill="#999">', _shortAddr(client_), '</text>',
            '<text x="32" y="268" font-family="monospace" font-size="9" fill="#555" letter-spacing="1">EXECUTOR</text>',
            '<text x="32" y="286" font-family="monospace" font-size="12" fill="#999">', _shortAddr(executor_), '</text>'
        ));
    }

    function _buildSVGFooter() private pure returns (string memory) {
        return string(abi.encodePacked(
            '<text x="200" y="340" font-family="monospace" font-size="8" fill="#2a2a2a" text-anchor="middle" letter-spacing="2">SOULBOUND  *  BURNS ON COMPLETION</text>',
            '<line x1="0" y1="460" x2="400" y2="460" stroke="#1a1a1a" stroke-width="1" stroke-dasharray="2,6"/>',
            '<circle cx="0"   cy="460" r="10" fill="#0a0a0a"/>',
            '<circle cx="400" cy="460" r="10" fill="#0a0a0a"/>',
            '<text x="200" y="486" font-family="monospace" font-size="9" fill="#2a2a2a" text-anchor="middle" letter-spacing="2">hexseal.net</text>',
            '</svg>'
        ));
    }

    // -------- HELPERS --------

    function _statusColor(uint8 s) private pure returns (string memory) {
        if (s == 1) return "#3b82f6"; // FUNDED   — blue
        if (s == 2) return "#22c55e"; // ACTIVE   — green
        if (s == 4) return "#ef4444"; // DISPUTED — red
        if (s == 3) return "#6b7280"; // COMPLETED
        if (s == 5) return "#8b5cf6"; // RESOLVED — purple
        if (s == 6) return "#f59e0b"; // REFUNDED — amber
        return "#6b7280";             // CREATED
    }

    function _statusStr(uint8 s) private pure returns (string memory) {
        if (s == 0) return "CREATED";
        if (s == 1) return "FUNDED";
        if (s == 2) return "ACTIVE";
        if (s == 3) return "COMPLETED";
        if (s == 4) return "DISPUTED";
        if (s == 5) return "RESOLVED";
        return "REFUNDED";
    }

    function _shortAddr(address addr) private pure returns (string memory) {
        bytes memory full = bytes(_toHex(addr));
        bytes memory r = new bytes(13);
        r[0] = full[0]; r[1] = full[1];
        r[2] = full[2]; r[3] = full[3]; r[4] = full[4]; r[5] = full[5];
        r[6] = '.'; r[7] = '.'; r[8] = '.';
        r[9] = full[38]; r[10] = full[39]; r[11] = full[40]; r[12] = full[41];
        return string(r);
    }

    function _formatUSDC(uint256 raw) private pure returns (string memory) {
        uint256 whole = raw / 1_000_000;
        uint256 frac  = (raw % 1_000_000) / 10_000;
        string memory f = frac == 0 ? "00"
            : frac < 10 ? string(abi.encodePacked("0", _uint2str(frac)))
            : _uint2str(frac);
        return string(abi.encodePacked(_uint2str(whole), ".", f, " USDC"));
    }

    function _bytes32HexShort(bytes32 b) private pure returns (string memory) {
        bytes memory r = new bytes(11);
        bytes memory HEX = "0123456789abcdef";
        for (uint256 i = 0; i < 4; i++) {
            uint8 v = uint8(b[i]);
            r[i * 2]     = HEX[v >> 4];
            r[i * 2 + 1] = HEX[v & 0xf];
        }
        r[8] = '.'; r[9] = '.'; r[10] = '.';
        return string(r);
    }

    function _toHex(address addr) private pure returns (string memory) {
        bytes memory b = abi.encodePacked(addr);
        bytes memory hex_ = new bytes(42);
        hex_[0] = '0'; hex_[1] = 'x';
        for (uint256 i = 0; i < 20; i++) {
            hex_[2 + i * 2]     = _hexChar(uint8(b[i]) >> 4);
            hex_[3 + i * 2]     = _hexChar(uint8(b[i]) & 0xf);
        }
        return string(hex_);
    }

    function _uint2str(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 temp = v;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buf = new bytes(digits);
        while (v != 0) { digits--; buf[digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(buf);
    }

    function _hexChar(uint8 v) private pure returns (bytes1) {
        return v < 10 ? bytes1(v + 48) : bytes1(v + 87);
    }
}
