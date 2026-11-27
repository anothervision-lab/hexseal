// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// ============================================================
// HEXSEAL — AgreementRenderer.sol
//
// The draughtsman of the deal certificate. A standalone contract, not a
// Diamond facet and not reachable through one: `Agreement.tokenURI` calls it
// directly, at an address fixed in the implementation's own code.
//
// ⚠️ WHY IT IS NOT A FACET, AND WHY THE CLONE DOES NOT ASK THE DIAMOND FOR THE
// ADDRESS. Reading the certificate is the one thing about a deal that must
// keep working when everything else stops. A clone that fetched the renderer's
// address from the diamond would hand the diamond a veto over what a wallet
// shows for a finished deal: unmount a selector, or let a facet revert, and
// every certificate goes blank at once. Measured on Base Sepolia, 18 September
// 2026: all 10 live clones render today, on four different implementations,
// with no call leaving the clone. This file keeps that property — the address
// is a compile-time constant of the implementation, so the only thing the
// picture depends on is one code-only, state-free contract.
//
// ⚠️ WHY THE ADDRESS IS A `constant` AND NOT AN `immutable`. Measured with
// solc 0.8.36: `type(C).runtimeCode` is a compile error for any contract that
// holds an immutable ("runtimeCode is not available for contracts containing
// immutable variables"). Four upgrade scripts and four tests use
// `type(Agreement).runtimeCode` to prove that the implementation deployed on
// chain is byte-for-byte what this checkout compiles. One immutable would have
// deleted that proof from the whole repository, so the address is fixed at
// compile time instead, and the renderer is deployed at a CREATE2 address
// nobody has to trust: same bytes, same salt, same address on every chain.
//
// ⚠️ THIS IS NOT src/SVGRenderer.sol, AND THE TWO MUST NOT BE MERGED. That one
// draws job receipts and service offers for JobReceiptFacet, in base64 JSON,
// off OpenZeppelin's Base64/Strings. This one draws the deal certificate, in
// `data:application/json;utf8,` — a different document, a different escaping
// contract with its caller (four layers, see below), and its own encoder. Both
// outputs are pinned byte for byte, by two different tests.
//
// WHAT MOVED HERE AND WHAT DID NOT. Everything that draws: the SVG, the
// attributes, the four escaping layers, the base64 encoder and the string
// helpers, lifted out of Agreement unchanged. What stayed in the clone is the
// only part that needs the clone's own storage — which tokens exist, and what
// the deal's status is right now.
// ============================================================

interface IAgreementRenderer {
    /// Everything the drawing reads. The clone owns all of it; nothing here is
    /// looked up anywhere else, which is why the render can be `pure`.
    struct Deal {
        address deal;          // the clone's own address, printed on the card
        address client;
        address executor;
        address arbiter;
        /// USDC, 6 decimals. WHAT THE ESCROW HOLDS NOW, not what the deal was
        /// signed for: the amount plus every ACCEPTED top-up. Until
        /// 20 September 2026 this field was the signed amount alone, and a
        /// deal topped up from $5 to $25 printed 5.00 on a sheet whose every
        /// other line was live -- measured on Base Sepolia deal
        /// 0xE25bED40…, 25 USDC in escrow against 5.00 on the card.
        ///
        /// ⚠️ A PENDING top-up is NOT in here and must not be. An unaccepted
        /// proposal goes back to the client when the deal closes, so counting
        /// it would print, as the escrow's contents, money on its way out.
        /// The clone computes this with the same expression its payout paths
        /// use; see `Agreement._pot()`.
        uint256 pot;
        /// Of that pot: how much arrived as accepted top-ups, and how many of
        /// them there were. BOTH ARE ZERO ON A DEAL WITH NONE, and then the
        /// drawing emits nothing for them at all -- not a line reading zero,
        /// nothing -- so such a sheet is byte for byte the sheet drawn before
        /// this field existed. test/AgreementCertificateSnapshot.t.sol holds
        /// that, and its header is where the measurement behind it is written
        /// down; see the longer note at `_extrasLine` below before moving
        /// anything it pins.
        uint256 extrasTotal;
        uint256 extrasCount;
        uint256 deadlineDays;
        uint8   status;        // Agreement.Status, same order
        string  terms;         // raw, as the human typed it — escaped here
        /// IS THE POT PRINTED ABOVE STILL INSIDE THE CLONE? One bit, and it is
        /// deliberately the DRAWING'S question rather than the clone's
        /// mechanism. The sheet needs to know whether it may say "this money is
        /// here"; a field called `finalized` would have been the clone's
        /// bookkeeping leaking into a contract that has no business knowing
        /// what finalization is, and six months from now nobody would remember
        /// that `finalized` meant "the money has gone".
        ///
        /// ⚠️ IT EXISTS BECAUSE `status` CANNOT ANSWER IT. `COMPLETED` and
        /// `REFUNDED` are both DERIVED FROM TIME in `Agreement.status()` — the
        /// auto-approve window running out, or the deadline plus its grace —
        /// and the clone answers the same enum value whether or not anybody has
        /// yet called `triggerAutoApprove` or `triggerDeadlineTimeout`. Before
        /// that press the pot is still sitting in the clone, and the drawing
        /// used to say nothing at all about it. `pot` cannot answer it either:
        /// it is `amount + extrasTotal`, a recorded figure and not a balance —
        /// see `Agreement._pot()`.
        ///
        /// WHO OWNS THE ANSWER: the clone, as `!_finalized`, and `_finalized`
        /// is written in exactly ONE place in src/Agreement.sol — inside
        /// `_complete`, immediately before the payout.
        ///
        /// ⚠️ THE ONE ANGLE IT GETS WRONG, NAMED HERE RATHER THAN PATCHED.
        /// The payouts are soft: `_complete` sets the flag, and `_payExecutor`
        /// or `_payClient` may then fail and book the sum as a debt, which
        /// leaves money inside a clone that reports `false` here. Such a sheet
        /// says nothing about money that is in fact present. That is the safe
        /// direction and it is chosen on purpose — withholding a true
        /// sentence costs a reader nothing, printing a false one on a document
        /// about money is what this bit exists to prevent — and the stranded
        /// sums are readable through `undeliveredPayout` and
        /// `undeliveredRefund`, which is where that state belongs.
        ///
        /// ⚠️ AND THIS STRUCT MAY NOT GROW AGAIN FOR FREE. A clone already
        /// born keeps calling the shape it was compiled against, so changing it
        /// would take `tokenURI` down on every live deal at once. It is changed
        /// here only because the renderer, the `Agreement` implementation and
        /// the deployer of this generation go to chain together: no live clone
        /// ever meets this shape against the old draughtsman, and no clone cut
        /// from the old deployer ever meets the new one.
        bool potStillHere;
    }

    function renderDeal(Deal calldata d) external pure returns (string memory);
}

contract AgreementRenderer is IAgreementRenderer {
    /// ⚠️ THE SAME ORDER AS `Agreement.Status`, AND THE CAST IS THE GUARD.
    /// The clone hands over a `uint8`; a value that is not one of the seven
    /// reverts here rather than being drawn as whatever the last `if` fell
    /// through to.
    enum Status {
        CREATED,
        FUNDED,
        ACTIVE,
        COMPLETED,
        DISPUTED,
        RESOLVED,
        REFUNDED
    }

    function renderDeal(Deal calldata d) external pure returns (string memory) {
        Status s = Status(d.status);
        string memory img = string(abi.encodePacked(
            "data:image/svg+xml;base64,",
            _base64Encode(bytes(_buildSVG(d, s)))
        ));
        return string(abi.encodePacked(
            'data:application/json;utf8,{"name":"HSEAL Deal ',
            _shortAddr(d.deal),
            '","description":"Escrow: ',
            _shortAddr(d.client), ' -> ', _shortAddr(d.executor),
            '","image":"', img,
            '","attributes":[', _buildAttrs(d, s), ']}'
        ));
    }

    function _buildAttrs(Deal calldata d, Status s) private pure returns (string memory) {
        return string(abi.encodePacked(
            '{"trait_type":"Status","value":"',       _statusStr(s),           '"},'
            // The POT, for the same reason the big number on the picture is
            // the pot: an attribute reading 5 beside a picture reading 25
            // would be two answers to one question, and a wallet shows the
            // attribute where the picture will not fit. The label is left
            // alone -- renaming it would move the bytes of every sheet ever
            // drawn, including the ones with no top-up at all.
            '{"trait_type":"Amount USDC","value":"',   _uint2str(d.pot / 1e6), '"},'
            '{"trait_type":"Deadline Days","value":"', _uint2str(d.deadlineDays), '"},'
            '{"trait_type":"Client","value":"',        _toHex(d.client),          '"},'
            '{"trait_type":"Executor","value":"',      _toHex(d.executor),        '"},'
            '{"trait_type":"Arbiter","value":"',       _toHex(d.arbiter),         '"},'
            // Layers 1, 2 and 4, in that order and only in that order: the
            // percent pass runs LAST, over finished JSON, because what it is
            // quoting for is the address the finished JSON travels inside.
            '{"trait_type":"Terms","value":"',
                _escapeUri(_escapeJson(_truncateStr(d.terms, 200))), '"}'
        ));
    }

    /// ⚠️ TWO SHEETS OUT OF ONE DRAUGHTSMAN, APPROVED AS DRAWINGS BY THE OWNER
    /// ON 24 NOVEMBER 2026. A deal that is funded and not yet started is a
    /// RECEIPT for money taken; a deal being worked is an AGREEMENT. Which of
    /// the two is drawn is decided here and nowhere else.
    ///
    /// ⚠️ THE OPENING TAG AND THE STYLESHEET ARE EMITTED BY `_svgOpen` FOR BOTH
    /// FORMS, UNCONDITIONALLY, AND THAT IS THE WHOLE SHAPE OF THIS FILE'S
    /// CHANGE. One selector added to that `<style>` for the receipt's sake
    /// would move the bytes of EVERY sheet there is, the six that must not
    /// move included — see the long note at `_extrasLine` and the header of
    /// test/AgreementCertificateSnapshot.t.sol. So the receipt's own looks are
    /// written on its elements instead, and the stylesheet below is the same
    /// string it was before either form existed.
    function _buildSVG(Deal calldata d, Status s) private pure returns (string memory) {
        string memory col = _statusColor(s);
        if (s == Status.FUNDED) {
            return string(abi.encodePacked(_svgOpen(), _buildReceipt(d, col)));
        }
        // ⚠️ READ OFF THE CLONE, NOT GUESSED FROM THE STATUS, SINCE
        // 24 NOVEMBER 2026. This line was `_theMoneyIsStillHere(s)`, a
        // function in this file that answered true for `ACTIVE` and `DISPUTED`
        // and nothing else. It was right about those two and silent about the
        // state that most needs a sentence: work handed in and nobody
        // answering, or a deadline long past, where `status()` already reads
        // COMPLETED or REFUNDED and not one cent has left the clone. No
        // function HERE could tell that apart from a settled deal — the clone
        // answers the same enum either way, and `pot` is a recorded figure
        // rather than a balance — so the clone states it outright instead.
        // See `Deal.potStillHere`.
        bool held = d.potStillHere;
        return string(abi.encodePacked(
            _svgOpen(),
            '<rect width="400" height="520" fill="#0d0d0d"/>',
            '<rect x="0" y="0" width="400" height="3" fill="', col, '"/>',
            '<text x="32" y="44" class="hd" fill="#555">DEAL AGREEMENT</text>',
            '<text x="368" y="44" class="hd" fill="#333" text-anchor="end">HSEAL</text>',
            '<text x="32" y="66" class="hd" fill="#444">', _shortAddr(d.deal), '</text>',
            _buildSVGStatus(col, _statusStr(s)),
            _buildSVGData(d, held),
            _escrowLines(held, s),
            _buildSVGFooter(held)
        ));
    }

    /// The canvas and the stylesheet, shared by both forms. 400x520 and
    /// #0d0d0d are the approved canvas; the stylesheet is BYTE-FROZEN, for the
    /// reason given above `_buildSVG`.
    function _svgOpen() private pure returns (string memory) {
        return
            '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="520" viewBox="0 0 400 520">'
            '<style>text{font-family:monospace}.lb{font-size:9px;fill:#555;letter-spacing:1}.v{font-size:12px;fill:#ccc}.vl{font-size:13px;fill:#fff}.hd{font-size:11px}.c{text-anchor:middle}line{stroke:#1e1e1e;stroke-width:1}</style>';
    }

    /// ⚠️ THE FUNCTION `_theMoneyIsStillHere(Status)` STOOD HERE UNTIL
    /// 24 NOVEMBER 2026, and what replaced it is `Deal.potStillHere` — one
    /// bit the clone fills in. It is written down because the function was not
    /// wrong, it was INCOMPLETE, and the incompleteness is the kind that reads
    /// as care: it answered true for `ACTIVE` and `DISPUTED` alone, on the
    /// argument that `COMPLETED` and `REFUNDED` mean the deal is over and the
    /// sentences would be addressed to nobody. But those two statuses are
    /// DERIVED FROM TIME, so both of them are also read on a deal whose pot
    /// nobody has collected yet, and on exactly those sheets the sentences are
    /// not merely true — they are the only place a person can learn that the
    /// money is still there and who has to press what to move it. No status
    /// this contract receives can tell the two apart.
    ///
    /// Three things on the card still hang off that one bit: the label over the
    /// big number (`AMOUNT HELD` against a bare `AMOUNT`), the sentences at the
    /// foot, and where the foot sits.

    function _buildSVGStatus(string memory col, string memory st) private pure returns (string memory) {
        return string(abi.encodePacked(
            '<line x1="32" y1="82" x2="368" y2="82"/>',
            '<rect x="32" y="94" width="336" height="36" rx="4" fill="', col, '" fill-opacity="0.12"/>',
            '<rect x="32" y="94" width="3" height="36" rx="1" fill="', col, '"/>',
            '<text x="46" y="117" font-size="14" fill="', col, '" font-weight="bold">', st, '</text>',
            '<line x1="32" y1="144" x2="368" y2="144"/>'
        ));
    }

    /// @param held what the clone answered in `Deal.potStillHere`.
    ///
    /// ⚠️ THE LABEL IS THE SHORTEST OF THE THREE CLAIMS THAT HANG OFF `held`,
    /// and it is the easiest to mistake for decoration. `AMOUNT HELD` says the
    /// escrow is holding this money right now; on a sheet whose pot was paid
    /// out months ago the same words would be a lie about money. So the word is
    /// added exactly where the sentences at the foot are added, and a sheet
    /// with nothing behind it keeps the bare `AMOUNT` — which is also what
    /// keeps a settled sheet byte-frozen.
    ///
    /// ⚠️ "A `COMPLETED` SHEET" STOOD IN THIS PARAGRAPH AS THE EXAMPLE OF
    /// MONEY LONG GONE, AND THAT WAS THE WHOLE MISTAKE OF 24 NOVEMBER 2026:
    /// `COMPLETED` is reached BY TIME as well as by a press, and in the first
    /// case the pot has not moved. The example is taken out rather than
    /// corrected, because the answer is no longer a status at all.
    ///
    /// Two string variables rather than a ternary: solc refuses a conditional
    /// whose branches are string literals of different lengths — the same
    /// obstacle, and the same way round it, as in `_extrasLine`.
    function _buildSVGData(Deal calldata d, bool held) private pure returns (string memory) {
        string memory amountLabel = "AMOUNT";
        if (held) amountLabel = "AMOUNT HELD";
        // ⚠️ "1 DAYS" WAS ON BOTH SHEETS UNTIL 24 NOVEMBER 2026, and it is
        // corrected in the same cycle as the sentences above because a drawing
        // reaches chain as executable bytes: a second pass over the wording
        // would cost another renderer, another implementation, another deployer
        // and another cut. The same two literals stand in `_buildReceiptProse`
        // in this file, in that sheet's own case and with its full stop.
        string memory unit = " days";
        if (d.deadlineDays == 1) unit = " day";
        return string(abi.encodePacked(
            '<text x="32"  y="164" class="lb">', amountLabel, '</text>',
            '<text x="200" y="164" class="lb">DEADLINE</text>',
            '<text x="32"  y="183" class="vl">', _formatUSDC(d.pot), '</text>',
            '<text x="200" y="183" class="vl">', _uint2str(d.deadlineDays), unit, '</text>',
            _extrasLine(d),
            '<line x1="32" y1="200" x2="368" y2="200"/>',
            '<text x="32" y="222" class="lb">CLIENT</text>',
            '<text x="32" y="240" class="v">', _shortAddr(d.client), '</text>',
            '<text x="32" y="268" class="lb">EXECUTOR</text>',
            '<text x="32" y="286" class="v">', _shortAddr(d.executor), '</text>',
            '<line x1="32" y1="304" x2="368" y2="304"/>',
            '<text x="32" y="326" class="lb">TERMS</text>',
            '<text x="32" y="344" font-size="10" fill="#555">', _escapeXml(_truncateStr(d.terms, 48)), '</text>'
        ));
    }

    /// The pointer under the big number: how much of the pot arrived as
    /// top-ups accepted after the deal was signed.
    ///
    /// ⚠️ NOTHING, NOT A ZERO, WHEN THERE ARE NONE. This function returning
    /// the empty string is what makes the sheet of a deal with no top-up byte
    /// for byte the sheet drawn before it existed — `abi.encodePacked` of ""
    /// adds no bytes. That is the main lock over this whole change, and it is
    /// measured rather than argued: test/AgreementCertificateSnapshot.t.sol
    /// pins fifteen scenes of the drawing, and its header carries both the
    /// measurement and the rules for ever moving one of those pins.
    ///
    /// ⚠️ THE SENTENCE HERE WAS CORRECTED ON 24 NOVEMBER 2026, AND THE OLD ONE
    /// IS NAMED BECAUSE IT IS WHAT A READER WOULD HAVE TRUSTED. It said "the
    /// seven hashes in test/AgreementCertificateSnapshot.t.sol were blessed at
    /// b9d26547 ... and they are unchanged". Both halves had gone stale: the
    /// pins are fourteen literals over fifteen scenes, not seven, and they were
    /// re-blessed at 2441af52. What moved there was not the drawing. The hash
    /// was taken off the raw document and put onto a canonical form of it — the
    /// two addresses a run's own deployment order decides, the clone's and the
    /// diamond's, replaced by fixed stubs — so that the pin answers to the
    /// picture instead of to a test flag. Everything else stayed under the
    /// hash, byte for byte, every byte of the image included, and the two
    /// addresses are now asserted by name and by place instead.
    ///
    /// ⚠️ AND THE CLAIM THIS PARAGRAPH EXISTS TO MAKE SURVIVED THE MOVE, which
    /// was measured before a single literal was touched: the RAW document of
    /// all fifteen scenes still hashed to the value blessed at b9d26547 — a
    /// build in which neither this function nor the pot existed — 15 of 15,
    /// with a wrong pairing checked and refused. So the descent of this
    /// guarantee from b9d26547 is unbroken; it simply lives in that
    /// measurement and in that file's header now, rather than in the literal
    /// itself. Read the header before touching this function.
    ///
    /// ⚠️ WHY IT IS A POINTER AND NOT A LIST. The top-ups themselves are
    /// already written down for ever in the clone's own storage — amount,
    /// the words that justified it, status, readable through `getExtra` —
    /// and there is no ceiling on how many a deal may have. A list would
    /// have no bound to lay out and would put a second copy of the record
    /// inside the picture, where nobody could correct it.
    ///
    /// ⚠️ NO NEW CSS CLASS, ON PURPOSE. The `<style>` element is emitted
    /// unconditionally by `_buildSVG`, so one more selector in it would move
    /// the bytes of EVERY sheet, including the ones this change must leave
    /// alone. The line borrows `.lb`, the label class already there, and sits
    /// at y=196 — below the value's baseline at 183 and above the divider at
    /// 200, the only gap on the card that belongs to the amount.
    function _extrasLine(Deal calldata d) private pure returns (string memory) {
        if (d.extrasCount == 0) return "";
        // Two literals rather than a ternary: solc refuses a conditional whose
        // branches are string literals of different lengths.
        string memory word = " EXTRAS, ";
        if (d.extrasCount == 1) word = " EXTRA, ";
        return string(abi.encodePacked(
            '<text x="32" y="196" class="lb">INCL. ',
            _uint2str(d.extrasCount), word, _formatUSDC(d.extrasTotal),
            '</text>'
        ));
    }

    /// The two sentences at the foot of the AGREEMENT, and the divider above
    /// them. Approved wording, 24 November 2026, transferred verbatim.
    ///
    /// ⚠️ NOTHING, NOT A HEDGED VERSION, WHEN THE MONEY HAS GONE — the same
    /// shape as `_extrasLine`, and for a stronger reason: `abi.encodePacked` of
    /// "" adds no bytes, so a sheet whose money has already been paid out stays
    /// byte for byte what it was. Which sheets those are is `Deal.potStillHere`
    /// and nothing else since 24 November 2026: the two scenes that go through
    /// arbitration, and the timed-out ones once somebody has actually pressed
    /// the door.
    ///
    /// ⚠️ AND THE SECOND SENTENCE IS NOT THE SAME SENTENCE ON A REFUND,
    /// 24 NOVEMBER 2026. "THE EXECUTOR HAS NOT BEEN PAID YET" is literally
    /// TRUE of a timed-out refund — nobody has been paid anything — and it
    /// is true about the WRONG PARTY. On that sheet the deadline and its grace
    /// ran out with nothing delivered, so the pot is waiting to go home to the
    /// CLIENT (`triggerDeadlineTimeout` hands it over entire), and a reader
    /// told that the executor has not been paid reads "the money is waiting for
    /// the executor". A sentence that is factually true and points at the wrong
    /// person is the same defect as a false one on a document about money, so
    /// the refund names where the money is going instead of who has not had it.
    ///
    /// The REFUNDED sheet that follows a dispute nobody judged never reaches
    /// this branch: that road is `triggerArbiterTimeout`, which finalizes, so
    /// `potStillHere` is false and no sentence is drawn at all. Which is
    /// correct — it splits the pot, and "back to the client" would be a
    /// second wrong addressee.
    ///
    /// ⚠️ NO NEW CSS CLASS, for the reason given above `_buildSVG`: the prose
    /// carries `font-size="9" fill="#555"` on each element, which is what the
    /// approved drawing's `.say` rule says, written where it costs the other
    /// sheets nothing.
    function _escrowLines(bool held, Status s) private pure returns (string memory) {
        if (!held) return "";
        // Two string variables rather than a ternary: solc refuses a
        // conditional whose branches are string literals of different lengths
        // — the same obstacle, and the same way round it, as in
        // `_extrasLine`. The first sentence and the three coordinates are
        // stated ONCE, so a sheet that is not a refund is byte for byte the
        // sheet drawn before this branch existed.
        string memory second = "THE EXECUTOR HAS NOT BEEN PAID YET.";
        if (s == Status.REFUNDED) second = "IT WILL GO BACK TO THE CLIENT.";
        return string(abi.encodePacked(
            '<line x1="32" y1="366" x2="368" y2="366"/>'
            '<text x="32" y="388" font-size="9" fill="#555">THE MONEY ABOVE IS STILL HERE, IN THIS CONTRACT.</text>'
            '<text x="32" y="403" font-size="9" fill="#555">',
            second,
            '</text>'
        ));
    }

    /// ⚠️ TWO FOOTERS, AND THE COORDINATES ARE THE REASON. The approved
    /// agreement puts the two sentences where the old footer stood, so on a
    /// sheet that carries them everything below the terms moves down by 24
    /// pixels: the divider 396 -> 424, SOULBOUND 428 -> 452, the domain
    /// 448 -> 472. A sheet without the sentences keeps the old three lines
    /// exactly, which is the other half of what freezes the six.
    function _buildSVGFooter(bool held) private pure returns (string memory) {
        if (held) {
            return
                '<line x1="32" y1="424" x2="368" y2="424"/>'
                '<text x="200" y="452" class="lb c" fill="#333">SOULBOUND</text>'
                '<text x="200" y="472" class="lb c" fill="#333">hexseal.net</text>'
                '</svg>';
        }
        return
            '<line x1="32" y1="396" x2="368" y2="396"/>'
            '<text x="200" y="428" class="lb c" fill="#333">SOULBOUND</text>'
            '<text x="200" y="448" class="lb c" fill="#333">hexseal.net</text>'
            '</svg>';
    }

    // ══════════════════════════════════════════════════════════════════════
    // THE RECEIPT, DRAWN ON `FUNDED` AND ON NOTHING ELSE.
    //
    // Approved as a drawing by the owner on 24 November 2026 and transferred
    // coordinate for coordinate: the same 400x520 canvas, the same #0d0d0d,
    // the status colour on the top rule and on the title.
    //
    // WHAT THE SHEET IS FOR. Between the money arriving and the executor
    // confirming the start, nothing has been agreed yet and there is no work
    // in progress to describe -- what has happened is that a sum was taken and
    // is being held. A receipt says that and says who is holding it; an
    // agreement form in that moment describes a thing that has not begun.
    //
    // ⚠️ NOT ONE NEW SELECTOR IN `<style>`, and every look below is written on
    // the element for that reason (see above `_buildSVG`). Three of the four
    // are ordinary presentation attributes; the fourth is not, and the
    // difference is a trap worth naming:
    //
    //   the prose       -- `font-size="9" fill="#555"`, no class. Nothing in
    //                      the stylesheet sets either property on a bare
    //                      `text`, so the attributes stand.
    //   the step digits -- the same, plus `font-weight="bold"`.
    //   the values      -- `font-size="11" fill="#ccc"`. Eleven and not the
    //                      stylesheet's twelve: the approved receipt's values
    //                      are a pixel smaller than the agreement's, which is
    //                      also why they do not borrow `.v`.
    //   the perforation -- `style="stroke:#2a2a2a"`, an INLINE DECLARATION and
    //                      deliberately not a `stroke="#2a2a2a"` attribute. A
    //                      presentation attribute is the weakest thing in the
    //                      cascade -- weaker than any rule in a stylesheet --
    //                      so the `line{stroke:#1e1e1e}` rule would win and
    //                      every perforation would come out the colour of a
    //                      solid divider. The dash pattern stays an attribute,
    //                      because no rule sets `stroke-dasharray` at all, and
    //                      `stroke-width:1` is still inherited from that same
    //                      rule, which is what the approved drawing wants.
    // ══════════════════════════════════════════════════════════════════════

    function _buildReceipt(Deal calldata d, string memory col) private pure returns (string memory) {
        return string(abi.encodePacked(
            '<rect width="400" height="520" fill="#0d0d0d"/>'
            '<rect x="0" y="0" width="400" height="3" fill="',
            col,
            '"/>'
            '<text x="32" y="44" class="hd" fill="',
            col,
            '">PAYMENT RECEIPT</text>'
            '<text x="368" y="44" class="hd" fill="#333" text-anchor="end">HSEAL</text>'
            '<text x="32" y="66" class="hd" fill="#444">',
            _shortAddr(d.deal),
            '</text>'
            '<line x1="32" y1="82" x2="368" y2="82" style="stroke:#2a2a2a" stroke-dasharray="3 5"/>'
            // The pot, and the big number carries no unit because the line
            // under it is the unit -- two answers to one question is the
            // defect `_buildAttrs` and `_extrasLine` are both written against.
            '<text x="200" y="124" class="c" font-size="30" fill="#fff" font-weight="bold">',
            _formatAmount(d.pot),
            '</text>'
            '<text x="200" y="146" class="c" font-size="12" fill="',
            col,
            '" letter-spacing="2">USDC HELD IN ESCROW</text>'
            '<line x1="32" y1="168" x2="368" y2="168" style="stroke:#2a2a2a" stroke-dasharray="3 5"/>'
            // WHO IS HOLDING IT, WHO PAID IT, WHO IT IS FOR, AND WHAT FOR.
            // `HELD BY` is the one line on either sheet whose value is a
            // constant rather than a field, and it is the sentence the whole
            // form exists to make: the money is in this contract, not with a
            // company.
            '<text x="32" y="192" class="lb">HELD BY</text>'
            '<text x="134" y="192" font-size="11" fill="#ccc">this contract</text>'
            '<text x="32" y="212" class="lb">PAID BY</text>'
            '<text x="134" y="212" font-size="11" fill="#ccc">',
            _shortAddr(d.client),
            '</text>'
            '<text x="32" y="232" class="lb">FOR</text>'
            '<text x="134" y="232" font-size="11" fill="#ccc">',
            _shortAddr(d.executor),
            '</text>'
            '<text x="32" y="252" class="lb">WORK</text>'
            '<text x="134" y="252" font-size="11" fill="#ccc">',
            // ⚠️ 32 BYTES HERE AND 48 ON THE AGREEMENT, AND THE DIFFERENCE IS
            // GEOMETRY RATHER THAN TASTE. This value starts at x=134 and the
            // card's content ends at 368, which is 234 pixels; at the
            // receipt's 11px monospace that is about 35 characters, three of
            // which the cut's own ellipsis needs. The agreement's line starts
            // at x=32 at 10px and has room for 48. Both budgets are counted in
            // BYTES and walked back off a half-letter by `_truncateStr` -- see
            // the note there about what a byte-counted cut did to a Cyrillic
            // term on chain.
            _escapeXml(_truncateStr(d.terms, 32)),
            '</text>'
            '<line x1="32" y1="272" x2="368" y2="272" style="stroke:#2a2a2a" stroke-dasharray="3 5"/>',
            _buildReceiptProse(d)
        ));
    }

    /// THE THREE SENTENCES, THE TWO NUMBERED STEPS AND THE RECEIPT'S FOOTER.
    ///
    /// ⚠️ TWO NUMBERS ABOUT THE WORLD OUTSIDE LIVE IN THIS PROSE, AND THEY HAVE
    /// DIFFERENT OWNERS. Both are spelled in words because the approved drawing
    /// spells them in words, and the difference between them is the whole of
    /// what can go wrong here:
    ///
    ///   THE DEADLINE     -- owned by `d.deadlineDays`, printed through
    ///                       `_uint2str`, never as a literal. A deal may be
    ///                       signed for any term, and a hard-coded "14" would
    ///                       be a straight lie on a document about money.
    ///   THE START WINDOW -- owned by `Agreement.ACTIVATION_WINDOW`, and it
    ///                       does NOT arrive here. There is no such field in
    ///                       `Deal` and this interface must not grow one: the
    ///                       clone and this contract are deployed separately
    ///                       and a clone already born keeps calling the shape
    ///                       it was compiled against, so a changed struct
    ///                       would take `tokenURI` down on every live deal at
    ///                       once. So the number is a hand-written COPY of a
    ///                       fact about the chain, "2 DAYS" below against
    ///                       `2 days` in src/Agreement.sol.
    ///
    /// ⚠️ WHO NOTICES IF THAT COPY GOES STALE, named because "nobody" is a
    /// finding and not an answer:
    /// `test_TheReceiptSaysTheRealActivationWindow` in
    /// test/AgreementCertificateSnapshot.t.sol builds the sentence out of the
    /// clone's own `ACTIVATION_WINDOW()` and demands it be on the drawn
    /// picture, so moving the constant without moving this line reddens by
    /// name. Measured that way round on 24 November 2026: the constant was put
    /// to 3 days, that test went red, and the fifteen pinned sheets stayed
    /// GREEN -- because the drawing had not changed, which is exactly the hole
    /// it covers and exactly why the pins cannot cover it.
    function _buildReceiptProse(Deal calldata d) private pure returns (string memory) {
        // The receipt's half of the singular; see the note in `_buildSVGData`.
        string memory unit = " DAYS.";
        if (d.deadlineDays == 1) unit = " DAY.";
        return string(abi.encodePacked(
            '<text x="32" y="294" font-size="9" fill="#555">THIS MONEY IS NOT HELD BY HEXSEAL. IT SITS IN</text>'
            '<text x="32" y="309" font-size="9" fill="#555">THIS CONTRACT AND NOBODY CAN MOVE IT ELSEWHERE.</text>'
            '<text x="32" y="336" font-size="9" fill="#555" font-weight="bold">1</text>'
            '<text x="48" y="336" font-size="9" fill="#555">THE EXECUTOR HAS 2 DAYS TO START. IF NOBODY</text>'
            '<text x="48" y="351" font-size="9" fill="#555">STARTS, ANYONE CAN SEND IT BACK TO THE CLIENT.</text>'
            '<text x="32" y="376" font-size="9" fill="#555" font-weight="bold">2</text>'
            '<text x="48" y="376" font-size="9" fill="#555">ONCE STARTED, THE WORK HAS ',
            _uint2str(d.deadlineDays),
            unit,
            '</text>'
            '<line x1="32" y1="400" x2="368" y2="400" style="stroke:#2a2a2a" stroke-dasharray="3 5"/>'
            '<text x="200" y="428" class="lb c" fill="#333">SOULBOUND</text>'
            '<text x="200" y="448" class="lb c" fill="#333">hexseal.net</text>'
            '</svg>'
        ));
    }

    function _statusColor(Status s) private pure returns (string memory) {
        if (s == Status.FUNDED)    return "#3b82f6";
        if (s == Status.ACTIVE)    return "#22c55e";
        if (s == Status.DISPUTED)  return "#ef4444";
        if (s == Status.COMPLETED) return "#6b7280";
        if (s == Status.RESOLVED)  return "#8b5cf6";
        if (s == Status.REFUNDED)  return "#f59e0b";
        return "#6b7280";
    }

    function _shortAddr(address addr) private pure returns (string memory) {
        bytes memory full = bytes(_toHex(addr)); // "0x" + 40 hex chars = 42 total
        bytes memory r = new bytes(13);          // "0xABCD...abcd"
        r[0] = full[0]; r[1] = full[1];
        r[2] = full[2]; r[3] = full[3]; r[4] = full[4]; r[5] = full[5];
        r[6] = '.'; r[7] = '.'; r[8] = '.';
        r[9] = full[38]; r[10] = full[39]; r[11] = full[40]; r[12] = full[41];
        return string(r);
    }

    /// Six decimals cut to two, WITHOUT a unit: "100.00".
    ///
    /// Split out of `_formatUSDC` on 24 November 2026 and not copied: the
    /// receipt's big number carries no unit because the line beneath it is the
    /// unit, and a second statement of this arithmetic is a second place for
    /// the rounding to drift. `_formatUSDC` is this plus four characters, so
    /// every sheet that ever printed "100.00 USDC" still prints the same bytes.
    function _formatAmount(uint256 raw) private pure returns (string memory) {
        uint256 whole = raw / 1_000_000;
        uint256 frac  = (raw % 1_000_000) / 10_000;
        string memory f = frac == 0 ? "00"
            : frac < 10 ? string(abi.encodePacked("0", _uint2str(frac)))
            : _uint2str(frac);
        return string(abi.encodePacked(_uint2str(whole), ".", f));
    }

    function _formatUSDC(uint256 raw) private pure returns (string memory) {
        return string(abi.encodePacked(_formatAmount(raw), " USDC"));
    }

    // ══════════════════════════════════════════════════════════════════════
    // FOUR LAYERS, IN THIS ORDER, AND THEY ARE NOT INTERCHANGEABLE.
    //
    // The terms are a string a human typed, and by the time anyone reads them
    // back they have been pasted into three nested documents at once. Each of
    // the three forbids different characters and spells its escapes
    // differently, so each gets a pass of its own. Every defect this cluster
    // was written against is one layer doing another one's job, or not being
    // there at all:
    //
    //   1. THE CUT      -- `_truncateStr`, counted in LETTERS, never in bytes.
    //   2. JSON         -- `_escapeJson`: '"', '\\', and every control byte.
    //   3. XML          -- `_escapeXml`: '&', '<', '>'. THE PICTURE ONLY.
    //   4. THE ADDRESS  -- `_escapeUri`: percent-encoding, ON TOP OF THE
    //                      FINISHED JSON, because the whole document leaves
    //                      here as a `data:` URI and a URI has its own rules.
    //
    // WHICH LAYERS RUN WHERE. The attribute takes 1, then 2, then 4. The
    // picture takes 1, then 3, and is then base64-encoded -- and base64's
    // alphabet (A-Z a-z 0-9 + / =) contains nothing layer 4 would touch, which
    // is why the picture needs no fourth pass and the attribute does.
    // ══════════════════════════════════════════════════════════════════════

    /// Cuts `s` down to at most `maxLen` BYTES, and never through the middle
    /// of a letter.
    ///
    /// ⚠️ WHY THE WALK-BACK. UTF-8 is variable width -- one byte for ASCII,
    /// two for Cyrillic, three for CJK, four for an emoji -- so a budget
    /// counted in bytes lands inside a letter whenever it falls mid-sequence,
    /// and what is left is not text. Measured on Base Sepolia deal
    /// 0x20E1E36A...: its picture ended in a replacement character, because
    /// the 48th byte of its terms was the second half of a Cyrillic letter.
    /// The owner read that as "the picture fell apart".
    ///
    /// A continuation byte is `10xxxxxx`. Stepping back over them costs at
    /// most three iterations and gives up at most one letter, which is why the
    /// budget is honoured to within one character rather than merely honoured.
    function _truncateStr(string memory s, uint256 maxLen) private pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length <= maxLen) return s;
        uint256 end = maxLen;
        while (end > 0 && uint8(b[end]) & 0xC0 == 0x80) end--;
        bytes memory r = new bytes(end + 3);
        for (uint256 i = 0; i < end; i++) r[i] = b[i];
        r[end] = '.'; r[end + 1] = '.'; r[end + 2] = '.';
        return string(r);
    }

    /// The deal's terms as the BODY OF A JSON STRING: the quote, the
    /// backslash, and every control byte 0x00-0x1F, which RFC 8259 forbids
    /// raw inside a string.
    ///
    /// ⚠️ WHAT THIS COST BEFORE IT EXISTED. Measured off Base Sepolia on
    /// 6 September 2026: deal 0xf45EdB8D... returns 2988 characters of
    /// `tokenURI` and JSON.parse dies on it -- "Bad control character in
    /// string literal at position 2870", a raw newline the client typed into
    /// the terms. Nothing rendered the token: not this project's pages, not a
    /// wallet, not an aggregator. It looked, from the outside, like the NFT
    /// did not exist.
    ///
    /// ⚠️ THIS IS NOT `_escapeXml` AND MUST NEVER BE MERGED WITH IT. The two
    /// documents forbid different characters and spell their escapes
    /// differently: `&` is nothing to JSON and fatal to XML, `\n` is fatal to
    /// JSON and ordinary whitespace in XML. One escaper serving both would be
    /// wrong in both places while looking like the problem had been solved.
    function _escapeJson(string memory s) private pure returns (string memory out) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        // Written in assembly, and only because the plain Solidity version of
        // these two loops came to 2_343 bytes against 1_331 of headroom --
        // measured 6 September 2026, 25_588 against the EIP-170 ceiling of
        // 24_576. The rules below are the same ones; what is gone is the
        // bounds check on every byte written and the zero-fill of a buffer
        // every byte of which is then overwritten.
        assembly ("memory-safe") {
            out := mload(0x40)
            let dst := add(out, 0x20)
            let src := add(b, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let c := byte(0, mload(add(src, i)))
                switch c
                // 0x5C is a backslash; the second byte is the escape letter.
                case 0x22 { mstore8(dst, 0x5C) mstore8(add(dst, 1), 0x22) dst := add(dst, 2) } // "
                case 0x5C { mstore8(dst, 0x5C) mstore8(add(dst, 1), 0x5C) dst := add(dst, 2) } // \\
                case 0x0A { mstore8(dst, 0x5C) mstore8(add(dst, 1), 0x6E) dst := add(dst, 2) } // \n
                case 0x0D { mstore8(dst, 0x5C) mstore8(add(dst, 1), 0x72) dst := add(dst, 2) } // \r
                case 0x09 { mstore8(dst, 0x5C) mstore8(add(dst, 1), 0x74) dst := add(dst, 2) } // \t
                default {
                    switch lt(c, 0x20)
                    // Everything else below 0x20 has no short form and needs
                    // the six-byte one. Kept rather than dropped: the terms
                    // are what an arbiter judges by, and quietly losing part
                    // of them is worse than showing an escape.
                    case 1 {
                        mstore8(dst, 0x5C)                                              // \
                        mstore8(add(dst, 1), 0x75)                                      // u
                        mstore8(add(dst, 2), 0x30)                                      // 0
                        mstore8(add(dst, 3), 0x30)                                      // 0
                        mstore8(add(dst, 4), byte(shr(4, c), "0123456789abcdef"))
                        mstore8(add(dst, 5), byte(and(c, 15), "0123456789abcdef"))
                        dst := add(dst, 6)
                    }
                    default { mstore8(dst, c) dst := add(dst, 1) }
                }
            }
            mstore(out, sub(dst, add(out, 0x20)))
            mstore(0x40, and(add(dst, 31), not(31)))
        }
    }

    /// The deal's terms as XML character data: `&`, `<` and `>`.
    ///
    /// ⚠️ THE ORDER-OF-REPLACEMENT TRAP IS NOT AVOIDED HERE, IT IS ABSENT.
    /// Doing this as successive string replacements has one right order --
    /// `&` first, or the ampersands the later passes write get escaped again
    /// -- and every other order is a bug that survives casual reading. This
    /// pass reads each INPUT byte exactly once and never looks at its own
    /// output, so no order exists to get wrong.
    ///
    /// Control bytes are turned into spaces rather than escaped, and that is
    /// the one place this differs from `_escapeJson`: XML 1.0 cannot carry
    /// 0x00-0x08, 0x0B, 0x0C or 0x0E-0x1F at all, not even as a numeric
    /// character reference, so there is nothing to escape them INTO. A picture
    /// carrying one is a picture no parser will open. Tab, newline and
    /// carriage return are legal and pass through.
    ///
    /// ⚠️ Not the same function as `_escapeJson`; see the warning there.
    function _escapeXml(string memory s) private pure returns (string memory out) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        // Assembly for the same reason as `_escapeJson`; see the note there.
        assembly ("memory-safe") {
            out := mload(0x40)
            let dst := add(out, 0x20)
            let src := add(b, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let c := byte(0, mload(add(src, i)))
                switch c
                case 0x26 { mstore8(dst, 0x26) mstore8(add(dst, 1), 0x61) mstore8(add(dst, 2), 0x6D) mstore8(add(dst, 3), 0x70) mstore8(add(dst, 4), 0x3B) dst := add(dst, 5) } // &amp;
                case 0x3C { mstore8(dst, 0x26) mstore8(add(dst, 1), 0x6C) mstore8(add(dst, 2), 0x74) mstore8(add(dst, 3), 0x3B) dst := add(dst, 4) } // &lt;
                case 0x3E { mstore8(dst, 0x26) mstore8(add(dst, 1), 0x67) mstore8(add(dst, 2), 0x74) mstore8(add(dst, 3), 0x3B) dst := add(dst, 4) } // &gt;
                default {
                    // Tab (0x09), newline (0x0A) and carriage return (0x0D)
                    // are the only control bytes XML 1.0 can carry; the rest
                    // become spaces, because there is nothing to escape them
                    // into.
                    if and(lt(c, 0x20), iszero(or(eq(c, 0x09), or(eq(c, 0x0A), eq(c, 0x0D))))) {
                        c := 0x20
                    }
                    mstore8(dst, c)
                    dst := add(dst, 1)
                }
            }
            mstore(out, sub(dst, add(out, 0x20)))
            mstore(0x40, and(add(dst, 31), not(31)))
        }
    }

    /// The finished JSON as part of an ADDRESS: the percent sign and the hash.
    ///
    /// ⚠️ WHAT A '#' DOES, MEASURED 6 SEPTEMBER 2026 AND NOT REASONED ABOUT.
    /// `tokenURI` hands back `data:application/json;utf8,{...}`, and that is a
    /// URI, so a URI parser reads it. Terms of "pay after review #2, budget
    /// 50% now" render 2_873 characters; Node's WHATWG `new URL()` puts the
    /// last 30 of them in `url.hash` -- an anchor, not data -- and what is
    /// left ends in the middle of a string, so `JSON.parse` dies with
    /// "Unterminated string in JSON at position 2824". Nothing renders. The
    /// same shape of failure as the raw newline, under a different rule, in a
    /// third document.
    ///
    /// ⚠️ AND WHY '%' IS NOT OPTIONAL, measured the same day. Terms of "budget
    /// 50% now" are fine for a reader that splits on the comma, and kill a
    /// reader that percent-decodes -- the correct way to read a URI -- with
    /// URIError "URI malformed". Beyond that, encoding '#' alone would make
    /// the two DIFFERENT inputs "%23" and "#" arrive as the same three
    /// characters, and nothing downstream could tell them apart again. The
    /// pair is the unit; neither half of it is any use alone.
    ///
    /// ⚠️ THE ORDER-OF-REPLACEMENT TRAP IS ABSENT HERE, NOT AVOIDED -- the
    /// same property `_escapeXml` has, and it matters more here. Written as
    /// successive replacements, '%' MUST be done first, or the escapes the
    /// later passes write get re-encoded and '#' comes out as "%2523". This
    /// pass reads each INPUT byte exactly once and never looks at its own
    /// output, so there is no order to get wrong.
    ///
    /// ⚠️ IT IS APPLIED TO THE TERMS, NOT TO THE WHOLE DOCUMENT, and that is a
    /// measurement rather than a preference. With ordinary terms the finished
    /// document holds ZERO '#' and ZERO '%' -- the addresses are hex, the
    /// numbers are decimal, the picture is base64 -- so the terms are the only
    /// place either character can enter, and a document-wide pass of this same
    /// rule would emit the same bytes for a pass over 2_800 of them instead of
    /// 200. A document-wide pass that encoded everything a URI reserves would
    /// be worse than useless: it would encode all 70 of the document's quotes
    /// too, and every reader that does NOT percent-decode would stop seeing a
    /// certificate at all -- including this project's own reader,
    /// `frontend/src/lib/tokenUriImage.ts`, which splits on the first comma
    /// and calls JSON.parse on the tail.
    ///
    /// ⚠️ Neither `_escapeJson` nor `_escapeXml`; see the roll call above.
    function _escapeUri(string memory s) private pure returns (string memory out) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        // Assembly for the same reason as the other two; see the note on
        // `_escapeJson`.
        assembly ("memory-safe") {
            out := mload(0x40)
            let dst := add(out, 0x20)
            let src := add(b, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let c := byte(0, mload(add(src, i)))
                // 0x25 is '%' and 0x23 is '#'. Both come out as "%" followed
                // by their two hex digits.
                switch or(eq(c, 0x25), eq(c, 0x23))
                case 1 {
                    mstore8(dst, 0x25)
                    mstore8(add(dst, 1), byte(shr(4, c), "0123456789ABCDEF"))
                    mstore8(add(dst, 2), byte(and(c, 15), "0123456789ABCDEF"))
                    dst := add(dst, 3)
                }
                default { mstore8(dst, c) dst := add(dst, 1) }
            }
            mstore(out, sub(dst, add(out, 0x20)))
            mstore(0x40, and(add(dst, 31), not(31)))
        }
    }

    function _base64Encode(bytes memory data) private pure returns (string memory) {
        bytes memory T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 len = data.length;
        if (len == 0) return "";
        uint256 outLen = 4 * ((len + 2) / 3);
        bytes memory result = new bytes(outLen);
        uint256 ri = 0;
        for (uint256 i = 0; i < len;) {
            uint256 a  = uint8(data[i]); i++;
            uint256 b2 = i < len ? uint8(data[i]) : 0; if (i < len) i++;
            uint256 c  = i < len ? uint8(data[i]) : 0; if (i < len) i++;
            uint256 buf = (a << 16) | (b2 << 8) | c;
            result[ri++] = T[buf >> 18];
            result[ri++] = T[(buf >> 12) & 63];
            result[ri++] = T[(buf >>  6) & 63];
            result[ri++] = T[buf         & 63];
        }
        if (len % 3 == 1) { result[outLen - 1] = '='; result[outLen - 2] = '='; }
        else if (len % 3 == 2) { result[outLen - 1] = '='; }
        return string(result);
    }
    // -------- STRING UTILS --------

    function _statusStr(Status s) private pure returns (string memory) {
        if (s == Status.CREATED)   return "CREATED";
        if (s == Status.FUNDED)    return "FUNDED";
        if (s == Status.ACTIVE)    return "ACTIVE";
        if (s == Status.COMPLETED) return "COMPLETED";
        if (s == Status.DISPUTED)  return "DISPUTED";
        if (s == Status.RESOLVED)  return "RESOLVED";
        return "REFUNDED";
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

    function _hexChar(uint8 v) private pure returns (bytes1) {
        return v < 10 ? bytes1(v + 48) : bytes1(v + 87);
    }
}
