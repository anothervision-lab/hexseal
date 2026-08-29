// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ════════════════════════════════════════════════════════════════════════════
// A golden print of the metadata a human actually sees.
//
// WHY. `DealMetadataFacet.getDealTokenURI` and `SVGRenderer` assemble the JSON
// and the SVG on chain, through OpenZeppelin's `Base64` and `Strings`. Until
// 15 August 2026 NOT ONE test looked at the content of that output: the only
// test touching tokenURI (Boards.t.sol) asserted that the call reverts without
// a renderer — it guarded the ABSENCE of the renderer, not what the renderer
// draws.
//
// The measurement that found the hole: an OpenZeppelin bump moved `Base64.sol`
// by +144/-29 lines and `Strings.sol` by +48/-24. There was nobody to ask
// "does the picture the user sees change because of this" — the whole suite is
// green either way. This file makes that question answerable.
//
// WHAT TO DO WHEN IT GOES RED. The bytes a wallet shows to the owner of the
// NFT have changed. That is not necessarily bad — but it has to be DELIBERATE.
// Look at the output (the test prints both strings in full under -vv), satisfy
// yourself that the new picture is the one you wanted, and then update the
// constant. Quietly fitting the constant to the new hash is precisely the
// failure this file was written against.
// ════════════════════════════════════════════════════════════════════════════

import "forge-std/Test.sol";
import "../src/facets/DealMetadataFacet.sol";
import "../src/SVGRenderer.sol";

contract MetadataRenderSnapshotTest is Test {
    DealMetadataFacet internal meta;
    SVGRenderer internal renderer;

    // The inputs are nailed down: the render is `pure`, so the output depends on
    // nothing but these and the OpenZeppelin code.
    address internal constant DEAL     = address(0xdEA110C0dE0000000000000000000000000000a1);
    address internal constant CLIENT   = address(0xc11E4700000000000000000000000000000000B2);
    address internal constant EXECUTOR = address(0xe8ec0700000000000000000000000000000000c3);
    uint256 internal constant AMOUNT   = 1_234_567_890;      // 1234.56789 USDC
    uint256 internal constant DAYS_    = 14;
    bytes32 internal constant TERMS    = keccak256("hexseal.metadata.snapshot.terms");

    function setUp() public {
        meta = new DealMetadataFacet();
        renderer = new SVGRenderer();
    }

    /// All seven deal statuses at once: each has its own picture and attributes.
    function testDealTokenURIRenderIsUnchanged() public view {
        bytes memory joined;
        for (uint8 status = 0; status < 7; status++) {
            string memory uri = meta.getDealTokenURI(
                DEAL, 0, status, CLIENT, EXECUTOR, AMOUNT, DAYS_, TERMS
            );
            console.log("--- status", status, "---");
            console.log(uri);
            joined = abi.encodePacked(joined, uri);
        }

        assertEq(
            keccak256(joined),
            0xcae50244f4ecc1268eea42189362e4fcb67d3db7d5a172a01ace2dbcb66e5745,
            "getDealTokenURI output changed. Read the file header: the constant may be refitted only after you have looked at the new picture and accepted it as correct."
        );
    }

    function testReceiptRenderIsUnchanged() public view {
        string memory out = renderer.renderReceipt(
            ISVGRenderer.ReceiptParams({
                tokenId: 42,
                client: CLIENT,
                // Deliberately multibyte input (a Russian job title), written as
                // \u escapes so the source stays ASCII without moving a single
                // byte — the blessed hash below stays the one a human blessed.
                title: "\u0420\u0435\u043c\u043e\u043d\u0442\u0020\u043a\u043e\u0444\u0435\u0432\u0430\u0440\u043a\u0438",
                amount: AMOUNT,
                deadlineDays: DAYS_,
                region: 3,
                createdAt: 1_760_000_000
            })
        );
        console.log(out);

        assertEq(
            keccak256(bytes(out)),
            0xae92d489923d9bd260a721eb54bd0337e0780507105389cc1817b76ed3879a63,
            "renderReceipt output changed; see the file header."
        );
    }

    function testOfferRenderIsUnchanged() public view {
        string memory out = renderer.renderOffer(
            ISVGRenderer.OfferParams({
                tokenId: 7,
                executor: EXECUTOR,
                // Multibyte again, same reason and same escaping as above.
                title: "\u0412\u0451\u0440\u0441\u0442\u043a\u0430\u0020\u043b\u0435\u043d\u0434\u0438\u043d\u0433\u0430",
                category: "\u0414\u0438\u0437\u0430\u0439\u043d",
                price: AMOUNT,
                deadlineDays: DAYS_,
                createdAt: 1_760_000_000,
                active: true,
                hiresCount: 5
            })
        );
        console.log(out);

        assertEq(
            keccak256(bytes(out)),
            0xec73470f6e748a0c51ce8138fe5a3b4f523dea2fe1bb3e2d0095c3601b8b6216,
            "renderOffer output changed; see the file header."
        );
    }
}
