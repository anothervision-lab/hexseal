// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./BoardsFixture.sol";

/**
 * GasCeilingBytes — what a call carrying a string actually costs, in BYTES.
 *
 * ⚠️ WHY THIS FILE EXISTS. An audit of the screen-versus-contract seam
 * suspected a third appearance of the "units change in the middle of the seam"
 * pattern, and said out loud that it could not confirm it: no test in `test/`
 * carried a Cyrillic `terms` at all. The relay client's fallback gas ceilings
 * were measured "at the form's actual maximum", and the form's maximum was a
 * `maxLength` — UTF-16 code units, i.e. roughly characters. The chain charges
 * per UTF-8 byte. Two thousand Cyrillic characters is four thousand bytes.
 *
 * This is that measurement. It is not an estimate on paper: the EVM is the
 * oracle and the ceiling is a literal copied from the client's gas table by
 * hand, so the two sides of the seam come from genuinely different places.
 *
 * ⚠️ WHY `requestService` AND NOT `mintJob`. It is the tightest of the
 * terms-carrying calls — 2_400_000 against a measured 1_868_986 at 2000 ASCII
 * characters, about 28% of headroom — so it is where a doubling of the string
 * lands first. Whatever holds here holds for the roomier neighbours.
 */
contract GasCeilingBytesTest is BoardsFixture {
    /// `requestService: 2_400_000n` — the relay client's fallback gas table.
    /// Copied by hand on purpose: derived from the thing under test it would
    /// only ever agree with itself.
    uint256 constant RELAY_FALLBACK_REQUEST_SERVICE = 2_400_000;

    /// `MAX_TERMS_BYTES` — the client's byte ceiling for `terms`. Same argument.
    uint256 constant MAX_TERMS_BYTES = 2000;

    function _mintService() internal returns (uint256 serviceId) {
        vm.startPrank(executor);
        usdc.approve(address(diamond), FEE);
        serviceId = ServiceBoardFacet(address(diamond)).mintService(
            "Smart Contract Dev", "I write secure Solidity", AMOUNT, DEADLINE, REGION
        );
        vm.stopPrank();
    }

    /// `n` copies of an ASCII letter — one byte each.
    function _latin(uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) out[i] = "a";
        return string(out);
    }

    /// `n` copies of Cyrillic U+0430 — TWO bytes each, so the returned
    /// string is `n` characters and `2n` bytes. This is the whole point.
    function _cyrillic(uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(n * 2);
        for (uint256 i = 0; i < n; i++) {
            out[i * 2] = 0xD0;
            out[i * 2 + 1] = 0xB0;
        }
        return string(out);
    }

    /// Gas burned by one `requestService` carrying `terms`.
    function _measure(string memory terms) internal returns (uint256 used) {
        uint256 serviceId = _mintService();
        vm.startPrank(client);
        usdc.approve(address(diamond), AMOUNT + JOB_FEE);
        uint256 before = gasleft();
        ServiceBoardFacet(address(diamond)).requestService(serviceId, AMOUNT, DEADLINE, terms, REGION);
        used = before - gasleft();
        vm.stopPrank();
    }

    /// The alphabet costs what the audit said it costs, and it is not close.
    function testCyrillicTermsCostTwiceTheStorage() public {
        uint256 latin = _measure(_latin(MAX_TERMS_BYTES));
        uint256 cyrillic = _measure(_cyrillic(MAX_TERMS_BYTES));

        emit log_named_uint("requestService, 2000 ASCII characters (2000 bytes)", latin);
        emit log_named_uint("requestService, 2000 Cyrillic characters (4000 bytes)", cyrillic);
        emit log_named_uint("difference", cyrillic - latin);

        // Same number of CHARACTERS, twice the BYTES, and the chain notices.
        assertGt(cyrillic, latin + 1_000_000, "2000 more bytes cost less than 1M gas?");
    }

    /**
     * THE FINDING, CONFIRMED. A brief typed to the form's old character limit
     * in any of the thirteen non-English locales does not fit under the
     * ceiling the relayer would fall back to.
     */
    function testCharacterCountedTermsBlowThroughTheRelayFallback() public {
        uint256 used = _measure(_cyrillic(MAX_TERMS_BYTES));
        // + 21_000 intrinsic: the ceiling has to cover the whole transaction,
        // not just execution (same argument as respondToRemoval's in relay.ts).
        assertGt(
            used + 21_000,
            RELAY_FALLBACK_REQUEST_SERVICE,
            "2000 Cyrillic characters now fit under the fallback -- the finding is stale, re-read it"
        );
    }

    /**
     * AND THE FIX, MEASURED. With the cap counted in bytes, the worst string
     * the form can now produce — 2000 BYTES, i.e. a thousand Cyrillic letters
     * — stays under the same ceiling with room to spare.
     */
    function testByteCountedTermsFitUnderTheRelayFallback() public {
        uint256 used = _measure(_cyrillic(MAX_TERMS_BYTES / 2));
        emit log_named_uint("requestService, 2000 BYTES of Cyrillic (1000 characters)", used);
        assertLt(
            used + 21_000,
            RELAY_FALLBACK_REQUEST_SERVICE,
            "the byte cap does not fit under the fallback -- raise the ceiling or lower the cap"
        );
    }
}
