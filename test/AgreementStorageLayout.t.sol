// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Agreement.sol";

/// Storage-layout lock for Agreement, living INSIDE the test suite.
///
/// WHY IT EXISTS. In the work behind 3fc08e67 (31 Aug 2026) a mutation swapped
/// `extrasTotal` and `pendingExtrasTotal` -- the two fields that decide whether
/// the money in a clone goes to the executor or back to the client -- and 1430
/// of 1430 tests stayed green. The only thing that noticed was
/// script/check-agreement-layout.sh, a shell gate outside `forge test`, and in
/// that same run it had already returned exit 3 ("layout NOT checked") once, on
/// a stale artifact cache. So the layout of the money fields was guarded by one
/// script that is able to quietly not check. This test is the second lock, and
/// it runs whenever anybody runs the suite.
///
/// The cost of getting this wrong is not a failed transaction. Every deal is an
/// EIP-1167 clone nailed to the implementation it was born from: a clone reads
/// its storage through the layout of that implementation forever, and no later
/// deployment reaches it. A reordered field is therefore unfixable for every
/// deal that already exists -- which is precisely how JobBoard was broken in
/// July 2026 (`termsHash` -> `terms`), where `getOpenJobs()` still reverts
/// Panic(0x22) on live Base Sepolia.
///
/// WHERE THE TRUTH COMES FROM, AND WHY THAT SOURCE. The compiler's own
/// storageLayout, out of the build artifact (`out/Agreement.sol/Agreement.json`,
/// key "storageLayout"), requested by `extra_output` in foundry.toml. That is
/// the same source of truth the shell gate uses -- `forge inspect Agreement
/// storageLayout --json` prints the artifact's storageLayout section, so both
/// locks read the compiler rather than re-deriving packing from the source text.
/// Nothing here parses `.sol`: field offsets are solc's answer, not ours.
///
/// The one thing the artifact cannot prove about itself is that it belongs to
/// THIS compile. `out/` is a cache and it goes stale (an old artifact, another
/// solc, an interrupted build). So every read here first checks that the
/// artifact's `deployedBytecode` is byte-for-byte the runtime code the compiler
/// just produced for the Agreement this test file imports -- `type(Agreement)
/// .runtimeCode`, inlined by solc at compile time from the current source, not
/// read back off disk. Different source, different settings or a different
/// compiler version all change that bytecode, so a stale artifact fails loudly
/// instead of certifying an old layout as current.
///
/// EXPECTED VALUES ARE A HUMAN-FIXED LITERAL. The table below is typed out by
/// hand and reviewed; it is NOT derived from the artifact, from the snapshot
/// file, or from anything else the test also checks. A lock whose expectation is
/// computed from the thing under test agrees with itself forever (recorded as
/// the 4th way to be fooled by a red count, docs/PROCESS.md).
///
/// WHAT IT CATCHES: reordering two fields (even two that share one slot),
/// inserting a field in the middle, widening a type, a shrunk or emptied layout
/// source, an artifact from another compile. WHAT IT ALLOWS: appending new
/// fields at the end -- append-only is the legal move, and a lock that forbids
/// the legal move gets deleted by the first person who needs it.
///
/// WHAT IT DOES **NOT** COVER, so script/check-agreement-layout.sh is NOT made
/// redundant by it: the order of the members of `enum Status` and
/// `enum ExtraStatus`. solc does not emit enum members in storageLayout at all
/// (the artifact's `types` entry for an enum carries only encoding/label/size),
/// which is why the gate's expander reads them out of the source text instead.
/// Reordering `Status` changes how every live clone's `_finalStatus` reads and
/// this test would stay green on it. The struct members of `Extra` ARE covered
/// here (test_ExtraStructMembersAreFrozen).
///
/// MEASURED 31 Aug 2026, one mutation at a time, full `forge test` each time
/// (1434 tests executed in every run -- the count is part of the result, since
/// zero reds and zero runs read identically):
///
///   swap extrasTotal <-> pendingExtrasTotal   1 red, test_StorageLayoutIsFrozen
///   new field inserted in the middle          1 red, test_StorageLayoutIsFrozen
///   uint16 _deadlineDays widened to uint32    2 red, test_StorageLayoutIsFrozen
///                                             + AgreementPacking's
///                                             testAllElevenValuesLiveInOneWord
///   new field appended at the end             0 red, 1434 passed (as intended)
///   artifact without the storageLayout key    4 red, all saying "NOT checked"
///   storage array cut to 30 of 35 fields      3 red, "fewer fields than known"
///   deployedBytecode of another compile       4 red, "from a different compile"
contract AgreementStorageLayoutTest is Test {
    /// One row of solc's `storageLayout.storage` array.
    ///
    /// Field ORDER is load-bearing: vm.parseJson hands the object back with its
    /// keys sorted alphabetically (astId, contract, label, offset, slot, type),
    /// so this struct has to list them in that order. `slot` arrives as a JSON
    /// string and is parsed to a number below; `contract` and `type` are
    /// reserved words in Solidity, hence the renames.
    struct RawField {
        uint256 astId;
        string contractName;
        string label;
        uint256 offset;
        string slot;
        string typeId;
    }

    /// One row of the hand-typed expectation.
    struct Field {
        string name;
        uint256 slot;
        uint256 offset;
        string typeLabel;
        uint256 size; // numberOfBytes, as solc counts them
    }

    string internal constant ARTIFACT = "out/Agreement.sol/Agreement.json";
    string internal constant OWNER = "src/Agreement.sol:Agreement";

    /// Number of fields the layout is known to have (measured 31 Aug 2026).
    /// Fewer than this means the source of truth is short -- truncated, emptied
    /// or half-written -- and the answer to that is "NOT checked", never "clean".
    uint256 internal constant KNOWN_FIELDS = 35;

    /// Attributes compared per field: name, slot, offset, type label, size,
    /// declaring contract. Asserted against the running count at the end so a
    /// loop that never ran cannot pass for a loop that found nothing wrong.
    uint256 internal constant CHECKS_PER_FIELD = 6;

    uint256 internal checks;

    // ---------------------------------------------------------------------
    // The frozen table. Slot and offset are solc's packing of the declaration
    // order in src/Agreement.sol: the four inherited MinimalERC721 mappings,
    // ReentrancyGuard's counter, ERC2771Context's forwarder, then Agreement's
    // own fields. Slot 6 packs `client` with `_initialized`, slot 10 packs the
    // whole life of the deal (five uint40 timestamps, five one-byte flags and
    // uint16 days = 32 bytes exactly), and slots 17 and 18 are the two totals
    // that decide who the money belongs to.
    // ---------------------------------------------------------------------
    function _expected() internal pure returns (Field[] memory f) {
        f = new Field[](KNOWN_FIELDS);
        f[0]  = Field("_owners",              0,  0, "mapping(uint256 => address)",                 32);
        f[1]  = Field("_balances",            1,  0, "mapping(address => uint256)",                 32);
        f[2]  = Field("_tokenApprovals",      2,  0, "mapping(uint256 => address)",                 32);
        f[3]  = Field("_operatorApprovals",   3,  0, "mapping(address => mapping(address => bool))",32);
        f[4]  = Field("_status",              4,  0, "uint256",                                     32);
        f[5]  = Field("_trustedForwarder",    5,  0, "address",                                     20);
        f[6]  = Field("client",               6,  0, "address",                                     20);
        f[7]  = Field("_initialized",         6, 20, "bool",                                         1);
        f[8]  = Field("executor",             7,  0, "address",                                     20);
        f[9]  = Field("arbiter",              8,  0, "address",                                     20);
        f[10] = Field("amount",               9,  0, "uint256",                                     32);
        f[11] = Field("_fundedAt",           10,  0, "uint40",                                       5);
        f[12] = Field("_activatedAt",        10,  5, "uint40",                                       5);
        f[13] = Field("_markedDoneAt",       10, 10, "uint40",                                       5);
        f[14] = Field("_disputedAt",         10, 15, "uint40",                                       5);
        f[15] = Field("_resolvedAt",         10, 20, "uint40",                                       5);
        f[16] = Field("_clientWonDispute",   10, 25, "bool",                                         1);
        f[17] = Field("_finalized",          10, 26, "bool",                                         1);
        f[18] = Field("_finalStatus",        10, 27, "enum Agreement.Status",                        1);
        f[19] = Field("_clientResponded",    10, 28, "bool",                                         1);
        f[20] = Field("_executorResponded",  10, 29, "bool",                                         1);
        f[21] = Field("_deadlineDays",       10, 30, "uint16",                                       2);
        f[22] = Field("terms",               11,  0, "string",                                      32);
        f[23] = Field("usdc",                12,  0, "address",                                     20);
        f[24] = Field("diamond",             13,  0, "address",                                     20);
        f[25] = Field("factory",             14,  0, "address",                                     20);
        f[26] = Field("extras",              15,  0, "mapping(uint256 => struct Agreement.Extra)",  32);
        f[27] = Field("nextExtraId",         16,  0, "uint256",                                     32);
        f[28] = Field("extrasTotal",         17,  0, "uint256",                                     32);
        f[29] = Field("pendingExtrasTotal",  18,  0, "uint256",                                     32);
        f[30] = Field("undeliveredRefund",   19,  0, "uint256",                                     32);
        f[31] = Field("undeliveredPayout",   20,  0, "uint256",                                     32);
        f[32] = Field("undeliveredFee",      21,  0, "uint256",                                     32);
        f[33] = Field("extraFee",            22,  0, "mapping(uint256 => uint256)",                 32);
        f[34] = Field("pendingExtraFeeTotal",23,  0, "uint256",                                     32);
    }

    /// The members of `struct Extra`, in declaration order. It is the value type
    /// of the `extras` mapping, so its members live at keccak-derived slots and
    /// appending to it is safe -- but reordering it moves live money exactly the
    /// way reordering a top-level field does, and the top-level type label
    /// ("mapping(uint256 => struct Agreement.Extra)") does not change when it
    /// happens.
    function _expectedExtraMembers() internal pure returns (Field[] memory f) {
        f = new Field[](3);
        f[0] = Field("amount", 0, 0, "uint256",                    32);
        f[1] = Field("terms",  1, 0, "string",                     32);
        f[2] = Field("status", 2, 0, "enum Agreement.ExtraStatus",  1);
    }

    // ---------------------------------------------------------------------
    // Reading the source of truth, with the "did it actually look?" checks.
    // ---------------------------------------------------------------------

    /// Reads the artifact and proves it belongs to this compile before anything
    /// is compared against it.
    function _artifactJson() internal view returns (string memory json) {
        json = vm.readFile(ARTIFACT);
        require(bytes(json).length > 0, "layout NOT checked: artifact is empty");

        bytes memory onDisk = vm.parseJsonBytes(json, ".deployedBytecode.object");
        require(onDisk.length > 0, "layout NOT checked: artifact carries no deployedBytecode");
        require(
            keccak256(onDisk) == keccak256(type(Agreement).runtimeCode),
            "layout NOT checked: out/Agreement.sol/Agreement.json is from a different compile "
            "than this test (stale cache, other solc, or an interrupted build) -- run forge clean && forge build"
        );
    }

    /// Decoding, reachable as an external call so the failure can be caught and
    /// renamed. Bare `abi.decode` on a shape it does not recognise reverts with
    /// no reason at all, and "EvmError: Revert" is precisely the kind of red
    /// that gets read as noise.
    function decodeFields(bytes memory encoded) external pure returns (RawField[] memory) {
        return abi.decode(encoded, (RawField[]));
    }

    /// Pulls `storageLayout.storage` out of the artifact. Every way of coming
    /// back empty-handed is a failure with its own message: a missing section is
    /// "NOT checked", never "nothing wrong".
    ///
    /// The empty-handed case is not hypothetical and it is not loud on its own.
    /// `vm.parseJson` does NOT fail on a path that matches nothing -- measured
    /// 31 Aug 2026 against an artifact with the storageLayout key deleted: the
    /// cheatcode returned successfully with an empty value, and it was the bare
    /// `abi.decode` below that reverted, reasonless. Every step therefore has
    /// its own guard rather than trusting the cheatcode to complain.
    function _fields(string memory json) internal view returns (RawField[] memory fields) {
        bytes memory encoded = vm.parseJson(json, ".storageLayout.storage");
        require(
            encoded.length > 0,
            "layout NOT checked: the artifact has no .storageLayout.storage section. foundry.toml must keep "
            'extra_output = ["storageLayout"] -- without it forge build writes the artifact without the layout'
        );

        try this.decodeFields(encoded) returns (RawField[] memory decoded) {
            fields = decoded;
        } catch {
            revert(
                "layout NOT checked: .storageLayout.storage did not decode into solc's field shape "
                "(astId, contract, label, offset, slot, type) -- the artifact format changed"
            );
        }

        require(
            fields.length >= KNOWN_FIELDS,
            "layout NOT checked: the layout source holds fewer fields than the 35 this contract is known to have"
        );
    }

    /// solc's own label and width for a type id, e.g. `t_uint40` -> ("uint40", 5).
    /// Bracket-quoted because type ids carry parentheses and commas
    /// (`t_mapping(t_uint256,t_struct(Extra)1047_storage)`), which the dotted
    /// json path form cannot address.
    function _typeMeta(string memory json, string memory typeId)
        internal
        pure
        returns (string memory label, uint256 size)
    {
        string memory base = string.concat(".storageLayout.types['", typeId, "']");
        label = vm.parseJsonString(json, string.concat(base, ".label"));
        size = vm.parseUint(vm.parseJsonString(json, string.concat(base, ".numberOfBytes")));
    }

    function _assertField(Field memory want, RawField memory got, string memory json, uint256 i) internal {
        string memory at = string.concat("field #", vm.toString(i), " (expected ", want.name, ")");

        assertEq(got.label, want.name, string.concat(at, ": wrong field, the order changed"));
        assertEq(vm.parseUint(got.slot), want.slot, string.concat(at, ": slot moved"));
        assertEq(got.offset, want.offset, string.concat(at, ": offset inside the slot moved"));
        assertEq(got.contractName, OWNER, string.concat(at, ": belongs to another contract"));

        (string memory typeLabel, uint256 size) = _typeMeta(json, got.typeId);
        assertEq(typeLabel, want.typeLabel, string.concat(at, ": type changed"));
        assertEq(size, want.size, string.concat(at, ": width changed"));

        checks += CHECKS_PER_FIELD;
    }

    // ---------------------------------------------------------------------
    // The locks.
    // ---------------------------------------------------------------------

    /// The layout of the first 35 fields is frozen: same names, same order,
    /// same slots, same offsets inside a slot, same types, same widths.
    function test_StorageLayoutIsFrozen() public {
        string memory json = _artifactJson();
        RawField[] memory got = _fields(json);
        Field[] memory want = _expected();

        for (uint256 i = 0; i < KNOWN_FIELDS; i++) {
            _assertField(want[i], got[i], json, i);
        }

        // Proof that the loop above actually ran: a green result with a zero
        // count would mean the lock was never applied, which is the failure
        // this whole file exists to make impossible.
        assertEq(checks, KNOWN_FIELDS * CHECKS_PER_FIELD, "layout NOT checked: comparisons were skipped");
        console2.log("agreement layout: fields compared", KNOWN_FIELDS);
        console2.log("agreement layout: attribute comparisons", checks);

        if (got.length > KNOWN_FIELDS) {
            console2.log("agreement layout: appended fields (allowed)", got.length - KNOWN_FIELDS);
            for (uint256 i = KNOWN_FIELDS; i < got.length; i++) {
                console2.log("  appended:", got[i].label, got[i].slot);
            }
        }
    }

    /// Appending is the one legal change and it has to STAY legal -- a lock that
    /// forbids the legal move is the first one somebody deletes. Nothing here
    /// asserts the layout is exactly 35 fields long; what it does assert is that
    /// an appended field cannot reach back into the frozen region, i.e. it starts
    /// at or after the last frozen slot.
    function test_AppendedFieldsAreAllowedButCannotReachBack() public view {
        RawField[] memory got = _fields(_artifactJson());
        assertGe(got.length, KNOWN_FIELDS, "layout is shorter than the frozen table");

        Field[] memory want = _expected();
        uint256 lastFrozenSlot = want[KNOWN_FIELDS - 1].slot;
        for (uint256 i = KNOWN_FIELDS; i < got.length; i++) {
            assertGe(
                vm.parseUint(got[i].slot),
                lastFrozenSlot,
                string.concat("appended field ", got[i].label, " sits inside the frozen region")
            );
        }
    }

    /// The members of `struct Extra` are frozen the same way, prefix-wise.
    /// The struct's type id carries an astId that shifts whenever anything above
    /// it in the file moves, so the entry is found by its label instead.
    function test_ExtraStructMembersAreFrozen() public {
        string memory json = _artifactJson();
        (bool ok, bytes memory rawIds) = address(vm).staticcall(
            abi.encodeWithSignature("parseJsonKeys(string,string)", json, ".storageLayout.types")
        );
        require(ok, "layout NOT checked: the artifact has no .storageLayout.types section");
        string[] memory ids = abi.decode(rawIds, (string[]));
        require(ids.length > 0, "layout NOT checked: the artifact's `types` section is empty");

        string memory extraId;
        uint256 found;
        for (uint256 i = 0; i < ids.length; i++) {
            (string memory label,) = _typeMeta(json, ids[i]);
            if (keccak256(bytes(label)) == keccak256(bytes("struct Agreement.Extra"))) {
                extraId = ids[i];
                found++;
            }
        }
        assertEq(found, 1, "layout NOT checked: struct Agreement.Extra not found exactly once in `types`");

        bytes memory raw =
            vm.parseJson(json, string.concat(".storageLayout.types['", extraId, "'].members"));
        RawField[] memory members = abi.decode(raw, (RawField[]));

        Field[] memory want = _expectedExtraMembers();
        assertGe(members.length, want.length, "struct Extra lost a member");

        for (uint256 i = 0; i < want.length; i++) {
            string memory at = string.concat("Extra.", want[i].name);
            assertEq(members[i].label, want[i].name, string.concat(at, ": wrong member, the order changed"));
            assertEq(vm.parseUint(members[i].slot), want[i].slot, string.concat(at, ": slot moved"));
            assertEq(members[i].offset, want[i].offset, string.concat(at, ": offset moved"));
            (string memory typeLabel, uint256 size) = _typeMeta(json, members[i].typeId);
            assertEq(typeLabel, want[i].typeLabel, string.concat(at, ": type changed"));
            assertEq(size, want[i].size, string.concat(at, ": width changed"));
            checks += 5;
        }
        assertEq(checks, want.length * 5, "layout NOT checked: member comparisons were skipped");
    }

    /// The lock's own smoke test: it fails when the source of truth cannot be
    /// read, which is the state that used to pass for "clean".
    function test_LayoutSourceIsReadableAndCurrent() public view {
        string memory json = _artifactJson(); // reverts unless the artifact matches this compile
        assertGt(bytes(json).length, 1000, "artifact suspiciously small");

        RawField[] memory got = _fields(json);
        assertGe(got.length, KNOWN_FIELDS, "layout source is short");
        assertEq(got[0].contractName, OWNER, "layout source is not Agreement's");
    }
}
