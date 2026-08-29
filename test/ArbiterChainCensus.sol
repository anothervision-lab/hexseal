// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";

// ============================================================
// A CENSUS OF THE LIVE CHAIN — AN INDEPENDENT ORACLE FOR CUTS
//
// WHY IT EXISTS. The cut benches used to assemble "today's layout on chain"
// out of `upgrade.replaceSelectors()` — that is, they derived the thing being
// CHECKED from the thing doing the CHECKING. A selector moved from Replace to
// Add disappeared from the bench together with the list, and the pre-flight
// honestly failed to find it mounted. The lock looked at itself in the mirror
// and was always satisfied.
//
// The price of that is the whole cut: `Replace` reverts on an unmounted
// selector ("Diamond: selector not found") and `Add` on a mounted one
// ("Diamond: selector exists"). An error either way rejects the production
// transaction AFTER both facets have already been deployed.
//
// A LITERAL COUNTER DOES NOT SAVE YOU. `routedBefore == 10 + 64` is a count,
// not an identity: it catches a single relocation and misses a SWAP. Measured:
// move the mounted `getArbiterChatKeys` into Add and the unmounted
// `getCleanVerdicts` into Replace, fixing the literal list of signatures to
// match — 843 green, 0 red, and the cut rejected outright in production.
//
// WHAT THIS FILE DOES. It hands over 64 selectors TAKEN FROM THE CHAIN and
// committed as data (test/fixtures/chain-2026-08-16-arbiter-selectors.json,
// with its own header: block, date, command, addresses). The expectation stops
// coming from the lists under test. Assertions over it are phrased as
// IDENTITIES rather than quantities:
//   Replace ∪ Remove == the census,  Add ∩ the census == ∅.
//
// ⚠️ WHY NOT A CHAIN FORK. `vm.createSelectFork` would be as honest an oracle
// as there is, but `forge test` would stop working without a network and an
// RPC key. The census gives the same thing for one read, done once and written
// into the repository.
// ============================================================
abstract contract ArbiterChainCensus is CommonBase {
    /// The census was taken from THIS diamond and THIS facet — pinned here so
    /// that a substituted file (a census of another contract, another network)
    /// cannot go through in silence.
    address internal constant CENSUS_DIAMOND = 0x760F07367888C62f7c2Dfb619A5e534132855ce5;
    address internal constant CENSUS_FACET = 0x1CF4c7DaA27f2241eafd8E818329719418403013;

    string internal constant CENSUS_PATH = "test/fixtures/chain-2026-08-16-arbiter-selectors.json";

    // ── TWO SNAPSHOTS OF PAST CHAIN STATES ──────────────────────────────
    //
    // The benches of two EXECUTED cuts used to obtain their layout by REWINDING
    // the census of 16 August — by one step (the presentation cut) and by two
    // (the chat-key cut). The rewind is correct, but it is a DERIVATION: it
    // lives exactly until the first error in the lists it is derived from.
    //
    // The same number now has two independent sources. Both snapshots were read
    // from the chain with a direct `facetFunctionSelectors` in archive blocks,
    // and the boundaries were found by binary search (the cut of 10 August
    // landed in block 45281831: 45281830 still had 0x42E9f172… with 54 selectors
    // and 167 routes in total, 45281831 already had 0xEDE8B010… with 56 and
    // 169). The rewind is NOT removed — it is checked against the snapshot, and
    // a divergence turns the test red.
    address internal constant CENSUS_FACET_BEFORE_10_AUG = 0x42E9f172D1c485dF8a7EbaD0ad7F8B7c648c3e44;
    address internal constant CENSUS_FACET_AFTER_10_AUG = 0xEDE8B010e5bAf63721DCA03a9f2cfCb0A6BC3655;

    string internal constant CENSUS_PATH_BEFORE_10_AUG =
        "test/fixtures/chain-2026-08-10-arbiter-selectors.json";
    string internal constant CENSUS_PATH_AFTER_10_AUG =
        "test/fixtures/chain-2026-08-14-arbiter-selectors.json";

    /// The common loader of a chain snapshot. The header is checked right here:
    /// diamond, facet, count, a non-empty block and date, and — above all — WHICH
    /// SCRIPT the snapshot was taken for. The file is read in full on every call:
    /// 54-64 lines, a cost measured in microseconds, whereas caching it in storage
    /// would require a non-view function and break `public view` on the
    /// composition tests.
    function _censusFromFile(
        string memory path,
        address expectedFacet,
        uint256 expectedCount,
        string memory forScript
    ) internal view returns (bytes4[] memory out) {
        string memory json = vm.readFile(path);

        require(
            vm.parseJsonAddress(json, ".diamond") == CENSUS_DIAMOND,
            "the census was taken from the wrong diamond"
        );
        require(
            vm.parseJsonAddress(json, ".facet") == expectedFacet,
            "the census was taken from the wrong facet"
        );
        require(vm.parseJsonUint(json, ".block") > 0, "the census header carries no block number");
        require(
            bytes(vm.parseJsonString(json, ".takenAt")).length > 0,
            "the census header carries no date of capture"
        );

        // ⚠️ THE CENTRAL CHECK OF THIS LOADER. The real trap is not "the census
        // is stale" (that is noticeable) but "an old census was taken for a NEW
        // cut script" — and that one goes through in silence, at the cost of a
        // whole cut.
        //
        // ⚠️ WHERE A LITERAL IS FORBIDDEN AND WHERE IT IS EQUIVALENT.
        // The lock works because the value comes from the script THAT THE BENCH
        // IS CHECKING: the author of the next cut copies the bench wholesale, but
        // their script is a new one and names itself differently, and the census
        // goes red. Hence the rule: a snapshot NATIVE to this bench must arrive
        // as `upgrade.scriptPath()`.
        // The rule does not extend to a snapshot of SOMEBODY ELSE'S cut (loaded
        // by the cross-checks of the rewind), and there a literal stays.
        //
        // ⚠️ THE ARGUMENT HERE USED TO BE FALSE, AND IT WAS REFUTED BY
        // MEASUREMENT. The earlier version explained the literal by saying the
        // name of a foreign script cannot be asked for without a `new`, and an
        // extra `new` is a nonce race. Wrong on both counts:
        //
        //   • `new UpgradePresentationRecord().scriptPath()` INSIDE the
        //     cross-check starts no race at all: `setUp` runs afresh before EVERY
        //     test, Foundry rolls state back between tests, and a `new` in the
        //     body of a test physically cannot shift addresses computed in
        //     `setUp` before it. Measured: 0 red;
        //   • and a file-level `string constant` in the script itself hands over
        //     the name with no deployment whatsoever — 859 green.
        //
        // A convincing-sounding false argument written into the code misleads the
        // next reader more surely than no argument at all — so it was replaced
        // rather than propped up.
        //
        // THE REAL REASON TO LEAVE THE LITERAL: there is no benefit. The lock on
        // one's own script works because the next cut has a DIFFERENT script — a
        // copy-paste of the bench drags the call along, and the call answers with
        // the new name. With a foreign script that does not happen: both an
        // `import` of the type and a quoted string travel by copy-paste EQUALLY
        // SILENTLY and both go on naming the previous cut. There is no reason to
        // pay for the same protection with an extra dependency of the bench on
        // somebody else's script.
        require(
            keccak256(bytes(vm.parseJsonString(json, ".forScript"))) == keccak256(bytes(forScript)),
            "the census was taken for a DIFFERENT cut script, so it does not describe what you are checking"
        );

        string[] memory raw = vm.parseJsonStringArray(json, ".selectors");
        require(
            raw.length == vm.parseJsonUint(json, ".count"),
            "the census header promises a different number of selectors than it holds"
        );
        require(raw.length == expectedCount, "the census holds a different number of selectors than the bench expects");

        out = new bytes4[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            bytes memory b = vm.parseBytes(raw[i]);
            require(b.length == 4, "a line in the census is not the length of a selector");
            out[i] = bytes4(b);
        }
    }

    /// The selectors mounted on the old ArbiterRegistryFacet in the live chain
    /// TODAY. `forScript` is taken from the very script under test
    /// (`UpgradeArbiterAccountability.scriptPath()`) rather than written here as a
    /// literal: a literal would travel into a new bench with the copy-paste and
    /// stay silent.
    function _chainCensus(string memory forScript) internal view returns (bytes4[] memory) {
        return _censusFromFile(CENSUS_PATH, CENSUS_FACET, 64, forScript);
    }

    /// The layout BEFORE the "arbiter chat key" cut (10 August 2026). An
    /// observation, not a rewind.
    ///
    /// `forScript` arrives as a PARAMETER rather than a literal: the bench this
    /// snapshot is native to must pass `upgrade.scriptPath()` here — the value
    /// taken from the script UNDER TEST itself. The boundary between "one's own"
    /// and "somebody else's" is worked out in the `_censusFromFile` docstring.
    function _chainCensusBefore10Aug(string memory forScript)
        internal view returns (bytes4[] memory)
    {
        return _censusFromFile(
            CENSUS_PATH_BEFORE_10_AUG,
            CENSUS_FACET_BEFORE_10_AUG,
            54,
            forScript
        );
    }

    /// The layout BETWEEN the cuts of 10 and 15 August 2026. An observation, not a
    /// rewind. `forScript` follows the same rule as its neighbour above.
    function _chainCensusAfter10Aug(string memory forScript)
        internal view returns (bytes4[] memory)
    {
        return _censusFromFile(
            CENSUS_PATH_AFTER_10_AUG,
            CENSUS_FACET_AFTER_10_AUG,
            56,
            forScript
        );
    }

    /// Two selector sets agree as SETS (order is irrelevant —
    /// `facetFunctionSelectors` does not guarantee it).
    function _assertSameSelectorSet(
        bytes4[] memory a,
        bytes4[] memory b,
        string memory whatA,
        string memory whatB
    ) internal pure {
        require(a.length == b.length, string.concat(whatA, " and ", whatB, " differ in count"));
        for (uint256 i = 0; i < a.length; i++) {
            require(
                _censusContains(b, a[i]),
                string.concat("a selector from '", whatA, "' is missing from '", whatB, "'")
            );
        }
        for (uint256 i = 0; i < b.length; i++) {
            require(
                _censusContains(a, b[i]),
                string.concat("a selector from '", whatB, "' is missing from '", whatA, "'")
            );
        }
    }

    /// The eight selectors that arrived with the "the chain as a witness to
    /// presentation" cut (15 August 2026), named by LITERAL SIGNATURES. They are
    /// what the census is rewound by one step with — back to the layout that cut
    /// found in place.
    ///
    /// ⚠️ WHY AS TEXT AND NOT `new UpgradePresentationRecord().addSelectors()`.
    /// The bench of the 10 August cut has to rewind the census by TWO steps, and
    /// for the sake of three lines it would have to DEPLOY a second script in
    /// `setUp`. Measured: one extra `new` in setUp shifts the test contract's
    /// nonce and with it the address of the locally deployed diamond, and a full
    /// `forge test` starts failing about once in twenty runs (2 of 40 against
    /// 0 of 40 without it).
    ///
    /// The mechanism this exposed, and which is worth knowing: `vm.setEnv` is
    /// PROCESS-GLOBAL, while `forge test` suites run IN PARALLEL. Three cut
    /// benches write `DIAMOND_ADDRESS` and read it back inside `run()`. The race
    /// is always there — it is harmless precisely because all three put THE SAME
    /// address into the variable: the test contract sits at one address for all
    /// three, and the sequence of `new`s in their `setUp` coincides. Let one suite
    /// deploy one contract more and its diamond's address moves, the foreign write
    /// stops matching its own, and `run()` goes with the loupe into a contract
    /// that in ITS EVM turned out to be something else: "EvmError: Revert" with
    /// not a word about the cause.
    ///
    /// The coincidence of addresses is an accidental one, and it rests on the
    /// nonce counter. The deterministic way to run the full suite is
    /// `forge test -j 1` (checked: no race at all, at a cost of 0.9 s against
    /// 0.18 s).
    ///
    /// What is checked against what here: the list below is checked against the
    /// production `upgrade.addSelectors()` by
    /// test_CensusRewindListMatchesTheCutsOwnAdd in the PresentationRecordUpgrade
    /// suite, and the production one against the same signatures in
    /// test_AddSelectorsAreTheEightNewSignatures. There is nowhere for them to
    /// drift apart quietly.
    function _presentationCutAddSelectors() internal pure returns (bytes4[] memory out) {
        out = new bytes4[](8);
        out[0] = bytes4(keccak256("getDisputeClaimedAt(address)"));
        out[1] = bytes4(keccak256("recordNoResponse(address)"));
        out[2] = bytes4(keccak256("getNoResponseAt(address)"));
        out[3] = bytes4(keccak256("getNoResponseFloor()"));
        out[4] = bytes4(keccak256("recordPresentationDigest(address,bytes32)"));
        out[5] = bytes4(keccak256("getPresentationDigests(address)"));
        out[6] = bytes4(keccak256("getPresentationDigestCount(address)"));
        out[7] = bytes4(keccak256("getPresentationDigestsPage(address,uint256,uint256)"));
    }

    function _censusContains(bytes4[] memory haystack, bytes4 needle) internal pure returns (bool) {
        for (uint256 i = 0; i < haystack.length; i++) {
            if (haystack[i] == needle) return true;
        }
        return false;
    }

    /// The census minus one selector. Needed by benches that mount part of the
    /// layout on a separate address (the bare-button double).
    function _censusWithout(bytes4[] memory census, bytes4 excluded)
        internal
        pure
        returns (bytes4[] memory out)
    {
        require(_censusContains(census, excluded), "the selector being subtracted is not in the census");
        out = new bytes4[](census.length - 1);
        uint256 k;
        for (uint256 i = 0; i < census.length; i++) {
            if (census[i] != excluded) out[k++] = census[i];
        }
    }

    /// REWINDING AN EXECUTED CUT BY ONE STEP.
    ///
    /// The census describes the chain TODAY. The benches of two ALREADY EXECUTED
    /// cuts (10 and 15 August 2026) need the layout from BEFORE them — and that
    /// follows from the census exactly: the cut added `added` and removed
    /// `removed`, so before it the state was `(state \ added) ∪ removed`.
    ///
    /// Why this is an honest oracle and not the same mirror. The Add and Remove
    /// lists of those scripts are locked down by LITERAL SIGNATURES in their own
    /// tests (eight signatures for the presentation cut, one for the chat-key
    /// cut) — that is, as text, not as `.selector` from the same contracts. The
    /// Replace list, the very thing the bench is built for, takes NO part in the
    /// rewind: it is precisely what is being checked.
    function _rewindCut(bytes4[] memory state, bytes4[] memory added, bytes4[] memory removed)
        internal
        pure
        returns (bytes4[] memory out)
    {
        for (uint256 i = 0; i < added.length; i++) {
            require(
                _censusContains(state, added[i]),
                "rewind: a selector added by the cut is not in the layout after it"
            );
        }
        for (uint256 i = 0; i < removed.length; i++) {
            require(
                !_censusContains(state, removed[i]),
                "rewind: a selector removed by the cut is still in the layout after it"
            );
        }

        out = new bytes4[](state.length - added.length + removed.length);
        uint256 k;
        for (uint256 i = 0; i < state.length; i++) {
            if (!_censusContains(added, state[i])) out[k++] = state[i];
        }
        for (uint256 i = 0; i < removed.length; i++) out[k++] = removed[i];
    }
}
