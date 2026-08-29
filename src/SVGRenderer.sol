// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — SVGRenderer.sol
// An external contract (not a Diamond facet) for on-chain SVG/JSON rendering.
// JobReceiptFacet reaches it through a staticcall (renderReceipt is `pure`) so
// that the facet's own bytecode is not inflated by SVG strings and helpers.
// The facet that used to call it, OfferNFTFacet, has been cut out of the
// Diamond and replaced by JobReceiptFacet.
// ============================================================

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface ISVGRenderer {
    struct OfferParams {
        uint256 tokenId;
        address executor;
        string  title;
        string  category;
        uint256 price;
        uint256 deadlineDays;
        uint256 createdAt;
        bool    active;
        uint256 hiresCount;
    }

    struct ReceiptParams {
        uint256 tokenId;
        address client;
        string  title;
        uint256 amount;
        uint256 deadlineDays;
        uint8   region;
        uint256 createdAt;
    }

    function renderOffer(OfferParams calldata p) external pure returns (string memory);
    function renderReceipt(ReceiptParams calldata p) external pure returns (string memory);
}

contract SVGRenderer is ISVGRenderer {
    using Strings for uint256;

    // ════════════════════════════════════════════════════════════════════════
    // PUBLIC ENTRY POINTS
    // ════════════════════════════════════════════════════════════════════════

    function renderOffer(OfferParams calldata p) external pure returns (string memory) {
        string memory svg    = _buildOfferSVG(p);
        string memory imgB64 = Base64.encode(bytes(svg));
        string memory json   = _buildOfferJSON(p, imgB64);
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    function renderReceipt(ReceiptParams calldata p) external pure returns (string memory) {
        string memory svg    = _buildReceiptSVG(p);
        string memory imgB64 = Base64.encode(bytes(svg));
        string memory json   = string(abi.encodePacked(
            '{"name":"Job Receipt #', p.tokenId.toString(),
            unicode'","description":"Hexseal — job posting receipt. Posted by ',
            _shortAddr(p.client),
            '.","image":"data:image/svg+xml;base64,', imgB64,
            '","attributes":['
              '{"trait_type":"Type","value":"JOB_RECEIPT"},'
              '{"trait_type":"Budget","value":"', _formatPrice(p.amount), ' USDC"},'
              '{"trait_type":"Region","value":"', _regionLabel(p.region), '"}'
            ']}'
        ));
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    // ════════════════════════════════════════════════════════════════════════
    // OFFER SVG
    // ════════════════════════════════════════════════════════════════════════

    function _buildOfferJSON(
        OfferParams calldata p,
        string memory imgB64
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(
            unicode'{"name":"Offer #', p.tokenId.toString(), unicode' — ', p.title,
            unicode'","description":"Hexseal Executor Offer — soulbound NFT.",',
            '"attributes":[',
                '{"trait_type":"Type","value":"OFFER"},',
                '{"trait_type":"Category","value":"', p.category, '"},',
                '{"trait_type":"Price USDC","value":"', _formatPrice(p.price), '"},',
                '{"trait_type":"Deadline Days","value":', p.deadlineDays.toString(), '},',
                '{"trait_type":"Active","value":', p.active ? 'true' : 'false', '},',
                '{"trait_type":"Hires","value":', p.hiresCount.toString(), '}',
            '],"image":"data:image/svg+xml;base64,', imgB64, '"}'
        ));
    }

    function _buildOfferSVG(OfferParams calldata p) internal pure returns (string memory) {
        return string(abi.encodePacked(
            _offerSvgHeader(),
            _offerSvgServiceBlock(p),
            _offerSvgFinancialBlock(p),
            _offerSvgFooterBlock(p),
            '</svg>'
        ));
    }

    function _offerSvgHeader() internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 380 500" width="380" height="500">',
            '<defs>',
              '<linearGradient id="gbg" x1="0%" y1="0%" x2="0%" y2="100%">',
                '<stop offset="0%" stop-color="#0d0d1f"/>',
                '<stop offset="100%" stop-color="#13132b"/>',
              '</linearGradient>',
            '</defs>',
            '<rect width="380" height="500" fill="url(#gbg)" rx="16"/>',
            '<rect width="380" height="5" fill="#6366f1" rx="2"/>',
            '<text x="190" y="46" text-anchor="middle" ',
              'font-family="monospace,Courier New" font-size="17" ',
              'fill="#6366f1" font-weight="bold" letter-spacing="2">HEXSEAL</text>',
            '<text x="190" y="64" text-anchor="middle" ',
              'font-family="monospace,Courier New" font-size="10" ',
              'fill="#334155" letter-spacing="3">EXECUTOR OFFER RECEIPT</text>',
            '<line x1="20" y1="78" x2="360" y2="78" stroke="#1e293b" stroke-width="1" stroke-dasharray="5,4"/>'
        ));
    }

    function _offerSvgServiceBlock(OfferParams calldata p) internal pure returns (string memory) {
        string memory titleStr = _truncate(_xmlEscape(p.title), 22);
        string memory catStr   = _truncate(_xmlEscape(p.category), 16);
        uint256 catW = bytes(catStr).length * 8 + 18;

        return string(abi.encodePacked(
            '<rect x="20" y="88" width="50" height="18" fill="#1e1e3f" rx="4"/>',
            '<text x="45" y="101" text-anchor="middle" ',
              'font-family="monospace,Courier New" font-size="9" fill="#6366f1">#',
              p.tokenId.toString(), '</text>',
            '<text x="80" y="101" ',
              'font-family="monospace,Courier New" font-size="9" fill="#475569">SERVICE</text>',
            '<text x="20" y="130" ',
              'font-family="monospace,Courier New" font-size="18" ',
              'fill="#f1f5f9" font-weight="bold">', titleStr, '</text>',
            '<rect x="20" y="140" width="', Strings.toString(catW), '" height="20" fill="#312e81" rx="5"/>',
            '<text x="29" y="154" ',
              'font-family="monospace,Courier New" font-size="10" fill="#a5b4fc">', catStr, '</text>',
            '<line x1="20" y1="172" x2="360" y2="172" stroke="#1e293b" stroke-width="1" stroke-dasharray="5,4"/>'
        ));
    }

    function _offerSvgFinancialBlock(OfferParams calldata p) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<text x="20" y="192" ',
              'font-family="monospace,Courier New" font-size="9" fill="#475569" letter-spacing="1">PRICE</text>',
            '<text x="20" y="226" ',
              'font-family="monospace,Courier New" font-size="28" ',
              'fill="#10b981" font-weight="bold">', _formatPrice(p.price), '</text>',
            '<text x="20" y="245" ',
              'font-family="monospace,Courier New" font-size="12" fill="#34d399">USDC</text>',
            '<text x="220" y="192" ',
              'font-family="monospace,Courier New" font-size="9" fill="#475569" letter-spacing="1">DEADLINE</text>',
            '<text x="220" y="226" ',
              'font-family="monospace,Courier New" font-size="28" ',
              'fill="#f1f5f9" font-weight="bold">', p.deadlineDays.toString(), '</text>',
            '<text x="220" y="245" ',
              'font-family="monospace,Courier New" font-size="12" fill="#64748b">DAYS</text>',
            '<line x1="20" y1="262" x2="360" y2="262" stroke="#1e293b" stroke-width="1" stroke-dasharray="5,4"/>'
        ));
    }

    function _offerSvgFooterBlock(OfferParams calldata p) internal pure returns (string memory) {
        string memory statusColor = p.active ? "#10b981" : "#475569";
        string memory statusLabel = p.active ? "ACTIVE" : "INACTIVE";
        string memory hiresColor  = p.hiresCount > 0 ? "#f59e0b" : "#334155";

        return string(abi.encodePacked(
            '<text x="20" y="282" ',
              'font-family="monospace,Courier New" font-size="9" fill="#475569" letter-spacing="1">EXECUTOR</text>',
            '<text x="20" y="302" ',
              'font-family="monospace,Courier New" font-size="13" fill="#94a3b8">',
              _shortAddr(p.executor), '</text>',
            '<text x="220" y="282" ',
              'font-family="monospace,Courier New" font-size="9" fill="#475569" letter-spacing="1">HIRES</text>',
            '<text x="220" y="302" ',
              'font-family="monospace,Courier New" font-size="28" fill="', hiresColor, '" font-weight="bold">',
              p.hiresCount.toString(), '</text>',
            '<line x1="20" y1="320" x2="360" y2="320" stroke="#1e293b" stroke-width="1" stroke-dasharray="5,4"/>',
            '<rect x="20" y="334" width="90" height="26" fill="', statusColor, '" rx="6"/>',
            '<text x="65" y="351" text-anchor="middle" ',
              'font-family="monospace,Courier New" font-size="11" fill="#fff" font-weight="bold">',
              statusLabel, '</text>',
            '<line x1="0" y1="440" x2="380" y2="440" stroke="#1e293b" stroke-width="1" stroke-dasharray="2,6"/>',
            '<circle cx="0"   cy="440" r="10" fill="#0d0d1f"/>',
            '<circle cx="380" cy="440" r="10" fill="#0d0d1f"/>',
            '<text x="190" y="462" text-anchor="middle" ',
              'font-family="monospace,Courier New" font-size="9" fill="#1e293b" letter-spacing="2">hexseal.net</text>',
            '<rect y="495" width="380" height="5" fill="#6366f1" rx="2"/>'
        ));
    }

    // ════════════════════════════════════════════════════════════════════════
    // JOB RECEIPT SVG
    // ════════════════════════════════════════════════════════════════════════

    function _buildReceiptSVG(ReceiptParams calldata p) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 380 520" width="380" height="520">',
            '<rect width="380" height="520" fill="#0a0a0a" rx="12"/>',
            '<rect width="380" height="4" fill="#ffffff" rx="2"/>',
            '<text x="190" y="38" text-anchor="middle" font-family="monospace,Courier New" font-size="16" fill="#ffffff" font-weight="bold" letter-spacing="2">HEXSEAL</text>',
            '<text x="190" y="54" text-anchor="middle" font-family="monospace,Courier New" font-size="9" fill="#444444" letter-spacing="3">JOB RECEIPT</text>',
            '<line x1="20" y1="66" x2="360" y2="66" stroke="#1e1e1e" stroke-width="1" stroke-dasharray="5,4"/>',
            _receiptHeader(p.tokenId, p.createdAt),
            _receiptItems(p),
            _receiptFooter(p.client),
            '<rect y="516" width="380" height="4" fill="#ffffff" rx="2"/>',
            '</svg>'
        ));
    }

    function _receiptHeader(uint256 tokenId, uint256 createdAt) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<text x="20" y="84" font-family="monospace,Courier New" font-size="9" fill="#555555">ORDER</text>',
            '<text x="360" y="84" text-anchor="end" font-family="monospace,Courier New" font-size="9" fill="#888888">#', _padId(tokenId), '</text>',
            '<text x="20" y="98" font-family="monospace,Courier New" font-size="9" fill="#444444">', _fmtDate(createdAt), '</text>',
            '<line x1="20" y1="110" x2="360" y2="110" stroke="#1e1e1e" stroke-width="1" stroke-dasharray="5,4"/>'
        ));
    }

    function _receiptItems(ReceiptParams calldata p) internal pure returns (string memory) {
        return string(abi.encodePacked(
            _receiptItemsTop(p),
            _receiptItemsBottom(p)
        ));
    }

    function _receiptItemsTop(ReceiptParams calldata p) internal pure returns (string memory) {
        return string(abi.encodePacked(
            _rowDark(130, "TITLE",    _truncate(_xmlEscape(p.title), 20)),
            _rowDark(148, "BUDGET",   string(abi.encodePacked(_formatPrice(p.amount), " USDC"))),
            _rowDark(166, "DEADLINE", string(abi.encodePacked(p.deadlineDays.toString(), " DAYS"))),
            _rowDark(184, "REGION",   _regionLabel(p.region)),
            '<line x1="20" y1="196" x2="360" y2="196" stroke="#1e1e1e" stroke-width="1" stroke-dasharray="5,4"/>'
        ));
    }

    function _receiptItemsBottom(ReceiptParams calldata p) internal pure returns (string memory) {
        // The fee was removed from the receipt on 28.07.2026: it is no longer
        // derived from the region, it is computed from the amount
        // (max(amount * feeBps, feeFloor)) and it is not passed into the receipt.
        // Printing it here would only be possible by recomputing it against the
        // current configuration — that is, by showing something other than what
        // the person actually paid.
        return string(abi.encodePacked(
            '<line x1="20" y1="242" x2="360" y2="242" stroke="#2e2e2e" stroke-width="1"/>',
            '<text x="20" y="266" font-family="monospace,Courier New" font-size="9" fill="#555555" letter-spacing="1">ESCROW</text>',
            '<text x="20" y="300" font-family="monospace,Courier New" font-size="32" fill="#ffffff" font-weight="bold">', _formatPrice(p.amount), '</text>',
            '<text x="20" y="318" font-family="monospace,Courier New" font-size="13" fill="#555555">USDC</text>',
            '<line x1="20" y1="334" x2="360" y2="334" stroke="#2e2e2e" stroke-width="1"/>'
        ));
    }

    function _receiptFooter(address client) internal pure returns (string memory) {
        return string(abi.encodePacked(
            '<text x="20" y="352" font-family="monospace,Courier New" font-size="8" fill="#555555" letter-spacing="1">CLIENT</text>',
            '<text x="20" y="370" font-family="monospace,Courier New" font-size="12" fill="#999999">', _shortAddr(client), '</text>',
            '<rect x="20" y="386" width="90" height="20" fill="#151515" rx="5"/>',
            '<text x="65" y="400" text-anchor="middle" font-family="monospace,Courier New" font-size="9" fill="#555555">GASLESS TX</text>',
            '<rect x="118" y="386" width="102" height="20" fill="#151515" rx="5"/>',
            '<text x="169" y="400" text-anchor="middle" font-family="monospace,Courier New" font-size="9" fill="#555555">BASE NETWORK</text>',
            unicode'<text x="190" y="428" text-anchor="middle" font-family="monospace,Courier New" font-size="8" fill="#333333" letter-spacing="2">SOULBOUND NFT · NON-TRANSFERABLE</text>',
            '<line x1="0" y1="454" x2="380" y2="454" stroke="#222222" stroke-width="1" stroke-dasharray="2,6"/>',
            '<circle cx="0"   cy="454" r="10" fill="#0a0a0a"/>',
            '<circle cx="380" cy="454" r="10" fill="#0a0a0a"/>',
            '<text x="190" y="476" text-anchor="middle" font-family="monospace,Courier New" font-size="9" fill="#333333" letter-spacing="2">hexseal.net</text>'
        ));
    }

    // ════════════════════════════════════════════════════════════════════════
    // PURE HELPERS
    // ════════════════════════════════════════════════════════════════════════

    function _rowDark(uint256 y, string memory label, string memory value) internal pure returns (string memory) {
        string memory ys = y.toString();
        return string(abi.encodePacked(
            '<text x="20" y="', ys, '" font-family="monospace,Courier New" font-size="10" fill="#555555">', label, '</text>',
            '<text x="360" y="', ys, '" text-anchor="end" font-family="monospace,Courier New" font-size="10" fill="#cccccc">', value, '</text>'
        ));
    }

    function _formatPrice(uint256 price) internal pure returns (string memory) {
        uint256 whole = price / 1_000_000;
        uint256 frac  = (price % 1_000_000) / 10_000;
        string memory fracStr = frac < 10
            ? string(abi.encodePacked("0", frac.toString()))
            : frac.toString();
        return string(abi.encodePacked(whole.toString(), ".", fracStr));
    }

    // Regions 4 (LATAM) and 5 (CA) were split off from 1 (Asia) and 3 (US) by
    // separate upgrades (UpgradeRegions7.s.sol), and 6 (AU) from 5 (CA) by a
    // separate upgrade of its own (UpgradeRegionAU.s.sol). Before that pair of
    // fixes "ASIA/LATAM" and "US/CA" were correct labels for regions that were
    // genuinely shared; they are now distinct regions with distinct fees (see
    // FactoryFacet.getAllFees()), so the label has to tell them apart as well.
    function _regionLabel(uint8 r) internal pure returns (string memory) {
        if (r == 0) return "CIS";
        if (r == 1) return "ASIA";
        if (r == 2) return "EUROPE";
        if (r == 3) return "US";
        if (r == 4) return "LATAM";
        if (r == 5) return "CA";
        return "AU";
    }

    function _padId(uint256 id) internal pure returns (string memory) {
        string memory s = id.toString();
        uint256 l = bytes(s).length;
        if (l == 1) return string(abi.encodePacked("000", s));
        if (l == 2) return string(abi.encodePacked("00",  s));
        if (l == 3) return string(abi.encodePacked("0",   s));
        return s;
    }

    function _shortAddr(address addr) internal pure returns (string memory) {
        bytes memory b    = abi.encodePacked(addr);
        bytes memory hex_ = "0123456789abcdef";
        bytes memory r    = new bytes(13);
        r[0] = '0'; r[1] = 'x';
        r[2]  = hex_[uint8(b[0]) >> 4];   r[3]  = hex_[uint8(b[0]) & 0xf];
        r[4]  = hex_[uint8(b[1]) >> 4];   r[5]  = hex_[uint8(b[1]) & 0xf];
        r[6]  = '.'; r[7] = '.'; r[8] = '.';
        r[9]  = hex_[uint8(b[18]) >> 4];  r[10] = hex_[uint8(b[18]) & 0xf];
        r[11] = hex_[uint8(b[19]) >> 4];  r[12] = hex_[uint8(b[19]) & 0xf];
        return string(r);
    }

    function _truncate(string memory s, uint256 maxChars) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 charCount = 0;
        uint256 byteIdx = 0;
        while (byteIdx < b.length) {
            if (charCount == maxChars) {
                bytes memory result = new bytes(byteIdx + 3);
                for (uint256 i = 0; i < byteIdx; i++) result[i] = b[i];
                result[byteIdx] = '.'; result[byteIdx+1] = '.'; result[byteIdx+2] = '.';
                return string(result);
            }
            uint8 c = uint8(b[byteIdx]);
            if      (c < 0x80) byteIdx += 1;
            else if (c < 0xE0) byteIdx += 2;
            else if (c < 0xF0) byteIdx += 3;
            else               byteIdx += 4;
            charCount++;
        }
        return s;
    }

    function _xmlEscape(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra = 0;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '<' || c == '>') extra += 3;
            else if (c == '&')        extra += 4;
            else if (c == '"')        extra += 5;
            else if (c == 0x27)       extra += 4;
        }
        if (extra == 0) return s;
        bytes memory result = new bytes(b.length + extra);
        uint256 j = 0;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if      (c == '<')  { result[j++]='&'; result[j++]='l'; result[j++]='t'; result[j++]=';'; }
            else if (c == '>')  { result[j++]='&'; result[j++]='g'; result[j++]='t'; result[j++]=';'; }
            else if (c == '&')  { result[j++]='&'; result[j++]='a'; result[j++]='m'; result[j++]='p'; result[j++]=';'; }
            else if (c == '"')  { result[j++]='&'; result[j++]='q'; result[j++]='u'; result[j++]='o'; result[j++]='t'; result[j++]=';'; }
            else if (c == 0x27) { result[j++]='&'; result[j++]='#'; result[j++]='3'; result[j++]='9'; result[j++]=';'; }
            else                { result[j++] = c; }
        }
        return string(result);
    }

    function _fmtDate(uint256 ts) internal pure returns (string memory) {
        uint256 dp  = ts / 86400;
        uint256 z   = dp + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y   = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp  = (5 * doy + 2) / 153;
        uint256 d   = doy - (153 * mp + 2) / 5 + 1;
        uint256 m   = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y++;
        uint256 tod = ts % 86400;
        uint256 hh  = tod / 3600;
        uint256 mm  = (tod % 3600) / 60;
        string memory ds = d  < 10 ? string(abi.encodePacked("0", d.toString()))  : d.toString();
        string memory hs = hh < 10 ? string(abi.encodePacked("0", hh.toString())) : hh.toString();
        string memory ms = mm < 10 ? string(abi.encodePacked("0", mm.toString())) : mm.toString();
        return string(abi.encodePacked(ds, " ", _month(m), " ", y.toString(), "  ", hs, ":", ms, " UTC"));
    }

    function _month(uint256 m) internal pure returns (string memory) {
        if (m ==  1) return "JAN"; if (m ==  2) return "FEB"; if (m ==  3) return "MAR";
        if (m ==  4) return "APR"; if (m ==  5) return "MAY"; if (m ==  6) return "JUN";
        if (m ==  7) return "JUL"; if (m ==  8) return "AUG"; if (m ==  9) return "SEP";
        if (m == 10) return "OCT"; if (m == 11) return "NOV";
        return "DEC";
    }
}
