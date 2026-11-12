#!/usr/bin/env python3
"""
Gate: every Agreement implementation that a LIVE CLONE actually executes has
its source published on the block explorer.

Run it through ./script/check-clone-implementations.sh (that wrapper checks the
working directory and the tools).

---------------------------------------------------------------------------
WHY THIS IS NOT THE SAME QUESTION AS ITS NEIGHBOUR

`check_sources_published.py` asks the deployer for its CURRENT implementation
and stops there. That is the right question about future deals and it is blind
to every deal that already exists, because an EIP-1167 clone carries the
implementation address inside its own body and never changes it:

    363d3d373d3d3d363d73 <20 bytes of address> 5af43d82803e903d91602b57fd5bf3

So each time the implementation is swapped, one more generation of clones goes
on running the old one, for ever. "22 of 22 published" is true about what will
be deployed next and says nothing about the sixteen contracts holding money
today.

Measured on 31 October 2026, and this gate is that measurement made repeatable:
sixteen registered deals executing SEVEN distinct implementations, six of them
published, one not -- and the implementation published that same day executes
ZERO live clones.

---------------------------------------------------------------------------
WHERE THE ROSTER COMES FROM, AND WHAT THAT CHOICE CANNOT SEE

⚠️ THE CHAIN, AND BY CALLS AND STORAGE READS RATHER THAN BY LOGS. Three roads
were available and the other two were rejected for measured reasons:

  * THE SUBGRAPH answers fast, but it is a derivative. It can lag, and a gate
    that says "all published" because the index has not caught up would be
    lying in the quiet direction.
  * EVENT LOGS over a wide block range are recorded in this project's own notes
    as returning a SILENT ZERO -- an empty answer that reads exactly like "there
    are no deals". That is the worst possible failure for a gate whose green
    means "nothing unpublished".
  * THE REGISTRY'S OWN ARRAY, which is what this uses. `totalAgreements()` is a
    call; the array itself has no accessor by index, so its sixteen entries are
    read with `eth_getStorageAt`.

⚠️ AND THE STORAGE READ IS GUARDED, because reading a slot is a claim about a
struct's field ORDER. `RegistryStorage.Layout` puts `allAgreements` second, so
its length lives at the storage position plus one -- and if a field is ever
inserted before it, that slot holds something else entirely and the addresses
read out of it would be rubbish that still looks like addresses. So the length
read from storage must EQUAL the number `totalAgreements()` returns, and when it
does not, this gate refuses rather than reporting. The storage position itself
is not a literal here: it is read out of `src/RegistryFacet.sol`, so the
constant has one owner and a rename makes this loud instead of silent.

WHAT THIS DOES NOT SEE, said plainly:

  * A CLONE THE REGISTRY NEVER RECORDED. Every road into a deal goes through
    `FactoryFacet`, which registers it -- but a clone deployed by hand, or one
    whose registration reverted, is invisible here. This gate is about the
    registry's roster, not about the set of all contracts ever deployed.
  * WHETHER THE PUBLISHED SOURCE MATCHES THE BYTECODE. "Published" here means
    the explorer holds a source for that address. Whether it is the source of
    THAT build is a different measurement (metadata tails, immutables), and the
    working journal's item about this half says so.
  * NOTHING ABOUT STATUS. All sixteen are read, finished or not. A completed
    deal's clone still holds its history, its certificate and its terms, and a
    stranger reading it needs the source as much as a live one's.

---------------------------------------------------------------------------
AND THE SECOND QUESTION: DOES THE CLONE ANSWER IN THE SHAPE WE READ?

A clone is free to differ from today's source for ever, and that is not a
hypothesis: measured by this gate on 31 October 2026, one of the seven live
implementations is built by a DIFFERENT COMPILER from the other six (v0.8.30
against v0.8.31). Bodies of different generations run side by side, so
"today's .sol" describes only some of them.

The failure this guards is already named in this tree and it is the nastiest
kind: the terms field was once a HASH, and a reader still declaring a hash
decodes the OFFSET as the value and throws NOTHING. A green screen with rubbish
where the agreement should be.

⚠️ THE CHAIN OF CUSTODY, WRITTEN OUT SO NOBODY READS THIS AS "FRONT END AGAINST
CHAIN". This gate compares the clone's answer against the shape declared in
`src/Agreement.sol`, and NOT against the front end's ABI. It does not have to:

    front end  <->  .sol        already held, by name, by the return censuses
                                (`frontend/src/lib/abiReturnCensus.test.ts`:
                                arity, types, and every name the front end
                                wrote; a mutation there reds it by name)
    .sol       <->  live clone  held here

So the two links close the circle `front end <-> .sol <-> clone` without a third
copy of the shape existing anywhere. Extracting the ABI out of TypeScript as
well would be that third copy, and the thing a third copy does is go stale in
the direction that keeps the gate quiet.

⚠️ AND THE DECODE IS STRICT ON PURPOSE: IT MUST ACCOUNT FOR EVERY BYTE. Simply
"decoding without an error" is not the test, because that is exactly what the
historical defect did. A head of twelve words decodes happily whether the fifth
word is a string's offset or a hash; what tells them apart is that a string also
has a TAIL, and a shape that does not declare one leaves those bytes unexplained.
So this decoder requires the declared shape to consume the whole return value,
and reports the leftover when it does not.

An enum in the declaration becomes `uint8`, resolved by finding `enum <Name> {`
in the same source -- the same rule the return census uses, for the same reason:
the source is the oracle and nothing here may guess a type it cannot find.

---------------------------------------------------------------------------
"NOT PUBLISHED" AND "COULD NOT ASK" ARE DIFFERENT ANSWERS

That rule is not re-implemented here: this gate CALLS the neighbour's
`published()`, which returns only 'yes' or 'no' and raises `Unmeasurable` for
everything else -- no key, no network, a refusal, a rate limit. An address that
could not be asked about is never counted as unpublished, and the run exits 3,
which is not a pass. The explorer key, the retries and the pause between
requests are the neighbour's too, for the same reason: one copy of each.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# ⚠️ IMPORTED, NOT COPIED. The explorer verdict, the key lookup, the batched
# code read and the two exception kinds all belong to the neighbouring gate; a
# second copy of them is a second thing to go stale, and the rule they encode
# ("the explorer being unable to answer is never a no") is exactly the rule this
# gate must not get wrong on its own.
from check_sources_published import (  # noqa: E402
    DEFAULT_RPC,
    HTTP_TIMEOUT,
    PAUSE,
    UA,
    Damaged,
    Unmeasurable,
    api_key,
    codes,
    diamond_from_censuses,
    published,
)

REGISTRY_SOURCE = "src/RegistryFacet.sol"
POSITION_RE = re.compile(
    r"REGISTRY_STORAGE_POSITION\s*=\s*(0x[0-9a-fA-F]{64})")
# The runtime body of an EIP-1167 clone. The address sits between the two halves.
# ⚠️ HOW MANY SUB-REQUESTS GO IN ONE BATCH, AND IT IS A MEASURED NUMBER, NOT A
# ROUND ONE. A JSON-RPC batch is counted by the node per CALL, not per HTTP
# request: measured 31 October 2026 against the public Base Sepolia endpoint,
# sixteen `eth_getStorageAt` followed at once by sixteen `eth_getCode` answered
# `-32007 25/second request limit reached`, and this gate correctly exited 3 --
# "NOT CHECKED". Correct, and useless: a gate that goes amber on its own traffic
# is a gate nobody reads. So the roster is asked for in chunks with a pause
# between them, which costs a second and buys a verdict.
BATCH = 8
BATCH_PAUSE = 0.6

CLONE_RE = re.compile(
    r"363d3d373d3d3d363d73([0-9a-f]{40})5af43d82803e903d91602b57fd5bf3")


def registry_position():
    """The diamond-storage base of the registry, read from the contract that
    declares it. Not a literal here: one owner for the constant, and a loud
    failure if it is renamed or moved."""
    if not os.path.isfile(REGISTRY_SOURCE):
        raise Damaged(f"{REGISTRY_SOURCE} is missing: nowhere to read the registry "
                      "storage position from")
    text = open(REGISTRY_SOURCE, encoding="utf-8", errors="replace").read()
    found = POSITION_RE.findall(text)
    if not found:
        raise Damaged(f"{REGISTRY_SOURCE} no longer declares REGISTRY_STORAGE_POSITION "
                      "as a 32-byte literal -- this gate reads the slot from there and "
                      "cannot guess it")
    if len({f.lower() for f in found}) > 1:
        raise Damaged(f"{REGISTRY_SOURCE} declares REGISTRY_STORAGE_POSITION more than "
                      f"once, with different values: {', '.join(found)}")
    return int(found[0], 16)


def cast_call_json(rpc, to, sig):
    p = subprocess.run(["cast", "call", to, sig, "--rpc-url", rpc],
                       capture_output=True, text=True)
    if p.returncode != 0:
        why = (p.stderr.strip() or p.stdout.strip() or "no output").splitlines()[0]
        raise Unmeasurable(f"`cast call {to} {sig}` exited {p.returncode}: {why[:200]}")
    out = p.stdout.strip()
    if not out:
        raise Unmeasurable(f"`cast call {to} {sig}` returned nothing")
    return out


def keccak_slot(slot_int):
    """keccak256 of the 32-byte slot number -- where a dynamic array's elements
    begin. Done with `cast keccak` rather than a hashing dependency, the same
    way the rest of this directory talks to the chain."""
    word = "0x" + format(slot_int, "064x")
    p = subprocess.run(["cast", "keccak", word], capture_output=True, text=True)
    if p.returncode != 0 or not p.stdout.strip():
        raise Unmeasurable(f"`cast keccak {word}` failed: "
                           f"{(p.stderr or p.stdout).strip()[:200]}")
    return int(p.stdout.strip(), 16)


def storage_batch(rpc, address, slots):
    """One batched `eth_getStorageAt` for the whole array. Batched for the same
    reason the neighbour batches `eth_getCode`: sixteen separate round trips to a
    public endpoint is sixteen chances for a flake, and a flake here would read
    as `0x0` -- which looks exactly like the zero address."""
    body = [{"jsonrpc": "2.0", "id": i, "method": "eth_getStorageAt",
             "params": [address, "0x" + format(s, "x"), "latest"]}
            for i, s in enumerate(slots)]
    req = urllib.request.Request(
        rpc, data=json.dumps(body).encode(),
        # User-Agent is load-bearing against the public endpoint; see the
        # neighbour's `codes()` for the measurement behind that.
        headers={"content-type": "application/json", "user-agent": UA},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            data = json.loads(r.read().decode())
    except (urllib.error.URLError, ValueError, OSError) as exc:
        raise Unmeasurable(f"eth_getStorageAt batch against {rpc} failed: {exc}")
    if not isinstance(data, list) or len(data) != len(slots):
        raise Unmeasurable(f"eth_getStorageAt batch against {rpc} answered something "
                           "unparseable")
    out = {}
    for e in data:
        i = e.get("id")
        if not isinstance(i, int) or "result" not in e:
            raise Unmeasurable(f"eth_getStorageAt batch: {str(e)[:150]}")
        out[i] = e["result"] or "0x0"
    if len(out) != len(slots):
        raise Unmeasurable("eth_getStorageAt batch answered fewer slots than asked")
    return [out[i] for i in range(len(slots))]


def word_to_address(word):
    v = int(word, 16)
    return "0x" + format(v, "040x")


def roster(rpc, diamond):
    """Every agreement the registry has recorded, read from the chain."""
    total_raw = cast_call_json(rpc, diamond, "totalAgreements()(uint256)")
    try:
        total = int(total_raw.split()[0])
    except (ValueError, IndexError):
        raise Unmeasurable(f"totalAgreements() answered {total_raw[:80]!r}")

    base = registry_position()
    length_slot = base + 1          # Layout: agreements mapping, then allAgreements
    (length_word,) = storage_batch(rpc, diamond, [length_slot])
    stored = int(length_word, 16)

    # ⚠️ THE GUARD ON THE WHOLE STORAGE ROAD. See the docstring: if the struct's
    # field order ever changes, this slot holds something else and the addresses
    # below would be rubbish shaped like addresses.
    if stored != total:
        raise Damaged(
            f"the registry's array length read from storage ({stored}) disagrees with "
            f"totalAgreements() ({total}). `allAgreements` is no longer the second field "
            f"of RegistryStorage.Layout, or the storage position moved. Nothing was "
            f"measured -- re-read the layout in {REGISTRY_SOURCE} and fix the slot here.")
    if total == 0:
        raise Damaged("the registry records no agreements at all. An empty roster reading "
                      "as a pass is how this class of gate dies, so it is refused.")

    start = keccak_slot(length_slot)
    slots = [start + i for i in range(total)]
    words = []
    for i in range(0, len(slots), BATCH):
        if i:
            time.sleep(BATCH_PAUSE)
        words.extend(storage_batch(rpc, diamond, slots[i:i + BATCH]))
    out = []
    for i, w in enumerate(words):
        addr = word_to_address(w)
        if int(addr, 16) == 0:
            raise Damaged(f"allAgreements[{i}] reads as the zero address: the slot "
                          "arithmetic or the layout is wrong, not the chain")
        out.append(addr)
    return out, total


def implementation_of(addr, code):
    """The address an EIP-1167 clone delegates to.

    ⚠️ A body that does not match the pattern is NOT reported as "no
    implementation". It means the assumption this gate is built on has broken
    for that address, and a guess there would be worse than a refusal."""
    if not code or code in ("0x", "0x0"):
        raise Damaged(f"{addr} is on the registry's roster and has no code at all")
    m = CLONE_RE.search(code.lower())
    if not m:
        raise Damaged(
            f"{addr} has code but it is not an EIP-1167 clone body: this gate walks from "
            f"a clone to its implementation through that pattern, and it is not there. "
            f"Read the code by hand before trusting any number from this run.")
    return "0x" + m.group(1)


SHAPE_SOURCE = "src/Agreement.sol"
GETTER = "getDetails"
RETURNS_RE = re.compile(
    r"function\s+" + GETTER + r"\s*\(\s*\)\s*external\s+view\s+returns\s*\(([^)]*)\)",
    re.S)
ENUM_RE = r"\benum\s+{}\s*\{{"
ELEMENTARY = {"address", "bool", "string", "bytes"}


def abi_form(decl, source):
    """One declared return type as the ABI spells it.

    An enum becomes `uint8`, found by looking for its declaration in the same
    source -- the rule `frontend/src/lib/abiReturnCensus.test.ts` already uses.
    A type this cannot account for is DAMAGE, never a guess: guessing here is
    how a reader ends up decoding an offset as a value."""
    if decl in ELEMENTARY or re.fullmatch(r"u?int(\d+)?", decl) or re.fullmatch(r"bytes\d+", decl):
        return decl
    if re.search(ENUM_RE.format(re.escape(decl)), source):
        return "uint8"
    raise Damaged(f"{SHAPE_SOURCE}: `{GETTER}` returns a `{decl}`, which is neither an "
                  f"elementary type nor an enum declared in that file. This gate decodes "
                  f"the chain's answer against that declaration and will not guess a type.")


def declared_shape():
    """The shape `.sol` says `getDetails` answers in: [(abi type, name), ...]."""
    if not os.path.isfile(SHAPE_SOURCE):
        raise Damaged(f"{SHAPE_SOURCE} is missing: nothing to take the shape from")
    source = open(SHAPE_SOURCE, encoding="utf-8", errors="replace").read()
    m = RETURNS_RE.search(source)
    if not m:
        raise Damaged(f"{SHAPE_SOURCE} no longer declares `{GETTER}() external view returns "
                      f"(...)` in a form this gate can read. The shape is taken from there "
                      f"and nowhere else.")
    out = []
    for part in m.group(1).split(","):
        words = part.replace("memory", " ").split()
        if not words:
            continue
        if len(words) < 2:
            raise Damaged(f"{SHAPE_SOURCE}: `{' '.join(words)}` in {GETTER}'s return list "
                          f"has no name; this gate reports fields by name")
        out.append((abi_form(words[0], source), words[-1]))
    if not out:
        raise Damaged(f"{SHAPE_SOURCE}: `{GETTER}` parsed to an empty return list")
    return out


def selector(sig):
    p = subprocess.run(["cast", "sig", sig], capture_output=True, text=True)
    if p.returncode != 0 or not p.stdout.strip():
        raise Unmeasurable(f"`cast sig {sig}` failed: {(p.stderr or p.stdout).strip()[:200]}")
    return p.stdout.strip()


def eth_call_batch(rpc, calls):
    """[(address, data)] -> [hex string]. Batched like the reads above, and for
    the same measured reason."""
    body = [{"jsonrpc": "2.0", "id": i, "method": "eth_call",
             "params": [{"to": a, "data": d}, "latest"]}
            for i, (a, d) in enumerate(calls)]
    req = urllib.request.Request(
        rpc, data=json.dumps(body).encode(),
        headers={"content-type": "application/json", "user-agent": UA}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            data = json.loads(r.read().decode())
    except (urllib.error.URLError, ValueError, OSError) as exc:
        raise Unmeasurable(f"eth_call batch against {rpc} failed: {exc}")
    if not isinstance(data, list) or len(data) != len(calls):
        raise Unmeasurable(f"eth_call batch against {rpc} answered something unparseable")
    out = {}
    for e in data:
        i = e.get("id")
        if not isinstance(i, int):
            raise Unmeasurable(f"eth_call batch: {str(e)[:150]}")
        if "error" in e:
            # ⚠️ A node refusing is never a verdict about the clone's shape.
            raise Unmeasurable(f"eth_call for {calls[i][0]}: {str(e['error'])[:150]}")
        out[i] = e.get("result") or "0x"
    return [out[i] for i in range(len(calls))]


class ShapeMismatch(Exception):
    """The clone answered, and not in the shape `.sol` declares. A finding about
    the chain -- never about the instrument, and never about the network."""


def decode_strict(data_hex, shape):
    """Decode against the declared shape, accounting for EVERY byte.

    Returns {name: value}. Raises ShapeMismatch with the reason, which is the
    whole point: "it decoded" is not the test (see the docstring -- a hash where
    a string belongs decodes silently), "it decoded and nothing was left over"
    is."""
    raw = bytes.fromhex(data_hex[2:] if data_hex.startswith("0x") else data_hex)
    if not raw:
        raise ShapeMismatch("the call returned no data at all")
    head = 32 * len(shape)
    if len(raw) < head:
        raise ShapeMismatch(f"the answer is {len(raw)} bytes; a head of {len(shape)} values "
                            f"needs {head}")
    values = {}
    tail_end = head
    for i, (typ, name) in enumerate(shape):
        word = raw[32 * i:32 * (i + 1)]
        if typ in ("string", "bytes"):
            off = int.from_bytes(word, "big")
            if off < head or off % 32 or off + 32 > len(raw):
                raise ShapeMismatch(
                    f"`{name}` is declared `{typ}`, so word {i} must be an offset into the "
                    f"answer; it reads {off} against an answer of {len(raw)} bytes with a "
                    f"{head}-byte head")
            length = int.from_bytes(raw[off:off + 32], "big")
            end = off + 32 + length
            if end > len(raw):
                raise ShapeMismatch(
                    f"`{name}` says it is {length} bytes long at offset {off}, which runs "
                    f"past the end of a {len(raw)}-byte answer")
            body = raw[off + 32:end]
            values[name] = body if typ == "bytes" else body
            padded = off + 32 + ((length + 31) // 32) * 32
            tail_end = max(tail_end, padded)
        elif typ == "address":
            if any(word[:12]):
                raise ShapeMismatch(f"`{name}` is declared `address` and word {i} has "
                                    f"non-zero padding: 0x{word.hex()}")
            values[name] = "0x" + word[12:].hex()
        else:
            bits = 256
            m = re.fullmatch(r"u?int(\d+)?", typ)
            if m and m.group(1):
                bits = int(m.group(1))
            if bits < 256 and int.from_bytes(word[: (256 - bits) // 8], "big"):
                raise ShapeMismatch(f"`{name}` is declared `{typ}` and word {i} has "
                                    f"non-zero padding: 0x{word.hex()}")
            values[name] = int.from_bytes(word, "big")
    # ⚠️ THE ARM THE HISTORICAL DEFECT WOULD HAVE TRIPPED. A shape that declares
    # no tail consumes the head and leaves the string's bytes unexplained.
    if tail_end != len(raw):
        raise ShapeMismatch(
            f"the declared shape accounts for {tail_end} of {len(raw)} bytes — "
            f"{len(raw) - tail_end} left over. A shape that explains only part of the "
            f"answer is the shape that reads an offset as a value")
    return values


def shape_of_clones(rpc, shape, probes):
    """One `getDetails` per implementation. `probes` is [(impl, clone)].

    ⚠️ ONE clone per implementation and not all sixteen: the question is about
    the BODY, and every clone of one implementation runs the same body. Asking
    them all would be the same reads for the same bytes."""
    sig = f"{GETTER}()"
    data = selector(sig)
    answers = eth_call_batch(rpc, [(clone, data) for _, clone in probes])
    out = {}
    terms_field = next((n for t, n in shape if t == "string"), None)
    for (impl, clone), answer_hex in zip(probes, answers):
        try:
            values = decode_strict(answer_hex, shape)
        except ShapeMismatch as exc:
            out[impl] = ("mismatch", clone, str(exc))
            continue
        if terms_field is None:
            out[impl] = ("ok", clone, "no string field is declared, so nothing to check")
            continue
        body = values[terms_field]
        try:
            text = body.decode("utf-8")
            utf8 = f"{len(body)} bytes, {len(text)} characters, {text.count(chr(10)) + 1} line(s)"
        except UnicodeDecodeError:
            # Not a mismatch of SHAPE: the bytes are a well-formed string, they
            # are simply not text. Said, not judged.
            utf8 = f"{len(body)} bytes, NOT valid UTF-8"
        out[impl] = ("ok", clone, f"`{terms_field}` is a string: {utf8}")
    return out


def main() -> int:
    rpc = os.environ.get("RPC_URL", DEFAULT_RPC)
    started = time.time()

    key, key_from = api_key()
    if not key:
        print("check-clone-implementations: NOT CHECKED (exit 3) -- no explorer key",
              file=sys.stderr)
        print("  Set ETHERSCAN_API_KEY or BASESCAN_API_KEY, in the environment or ./.env.",
              file=sys.stderr)
        print("  A missing key is not a pass: nothing was asked.", file=sys.stderr)
        return 3

    explorer_calls = 0
    try:
        diamond, census_count = diamond_from_censuses()
        clones, total = roster(rpc, diamond)
        # ⚠️ The neighbour's `codes()` is called in chunks rather than edited:
        # that gate's roster is 21 addresses and has never tripped the limit, and
        # changing a gate in use is not this one's business.
        code = {}
        for i in range(0, len(clones), BATCH):
            if i:
                time.sleep(BATCH_PAUSE)
            code.update(codes(rpc, clones[i:i + BATCH]))

        # clone -> implementation, and implementation -> the clones running it
        behind = {}
        for c in clones:
            impl = implementation_of(c, code.get(c.lower(), "0x"))
            behind.setdefault(impl.lower(), []).append(c)

        print(f"check-clone-implementations: diamond {diamond} "
              f"(agreed by {census_count} census file(s))")
        print(f"  registry roster: {total} agreement(s), "
              f"{len(behind)} distinct implementation(s) behind them")

        verdicts = {}
        for impl in sorted(behind):
            state, detail = published(impl, key)
            explorer_calls += 1
            verdicts[impl] = (state, detail)
            time.sleep(PAUSE)

        unpublished = [i for i, (s, _) in verdicts.items() if s == "no"]

        # ── the second question: does each body answer in the declared shape ──
        shape = declared_shape()
        time.sleep(BATCH_PAUSE)
        probes = [(impl, sorted(behind[impl])[0]) for impl in sorted(behind)]
        shapes = shape_of_clones(rpc, shape, probes)
        mismatched = [i for i, (st, _, _) in shapes.items() if st == "mismatch"]

        print(f"  the shape `{GETTER}` is declared with in {SHAPE_SOURCE}: "
              f"{len(shape)} value(s), "
              + ", ".join(f"{t} {n}" for t, n in shape[:3]) + ", …")

        for impl in sorted(behind, key=lambda i: (-len(behind[i]), i)):
            state, detail = verdicts[impl]
            mark = "ok " if state == "yes" else "NOT"
            n = len(behind[impl])
            print(f"  [{mark}] {impl}  {n} clone(s)  {detail}")
            if state == "no":
                for c in behind[impl]:
                    print(f"         runs: {c}")
            st, clone, why = shapes.get(impl, ("?", "?", "not asked"))
            print(f"        shape [{'ok ' if st == 'ok' else 'BAD'}] via {clone}: {why}")

        # ⚠️ The deployer's CURRENT implementation is printed beside the roster
        # because the difference is the whole point of this gate: it is the one
        # the neighbour checks, and it may run nothing at all.
        try:
            deployer = cast_call_json(rpc, diamond, "getAgreementDeployer()(address)").split()[0]
            current = cast_call_json(rpc, deployer, "implementation()(address)").split()[0]
            runs = len(behind.get(current.lower(), []))
            print(f"  the deployer's current implementation {current} runs {runs} "
                  f"of these {total} clone(s)"
                  + ("  <-- and so is not among them at all" if runs == 0 else ""))
        except Unmeasurable as exc:
            # Not fatal: it is context, not the verdict.
            print(f"  (could not read the deployer's current implementation: {exc})")

        took = time.time() - started
        print(f"  {explorer_calls} explorer request(s), {took:.1f}s, key from {key_from}")

        if unpublished or mismatched:
            if unpublished:
                print(f"check-clone-implementations: {len(unpublished)} implementation(s) "
                      f"with NO published source, run by live clones:", file=sys.stderr)
                for impl in unpublished:
                    print(f"    {impl} -- {len(behind[impl])} clone(s)", file=sys.stderr)
                print("  A stranger holding one of those deals cannot read the code that "
                      "holds his money.", file=sys.stderr)
            if mismatched:
                print(f"check-clone-implementations: {len(mismatched)} implementation(s) "
                      f"answer `{GETTER}` in a shape {SHAPE_SOURCE} does not declare:",
                      file=sys.stderr)
                for impl in mismatched:
                    _, clone, why = shapes[impl]
                    print(f"    {impl} -- read through {clone}", file=sys.stderr)
                    print(f"      {why}", file=sys.stderr)
                print("  ⚠️ DO NOT 'FIX' THIS BY WIDENING THE READER. What to show a person "
                      "holding a deal of an older generation is a product decision, and a "
                      "reader that accepts both shapes is the reader that decodes an offset "
                      "as a value.", file=sys.stderr)
            return 1
        print(f"check-clone-implementations: every implementation a live clone runs is "
              f"published, and all {len(shapes)} answer `{GETTER}` in the shape "
              f"{SHAPE_SOURCE} declares")
        return 0

    except Damaged as exc:
        print(f"check-clone-implementations: DAMAGED (exit 2) -- {exc}", file=sys.stderr)
        return 2
    except Unmeasurable as exc:
        print(f"check-clone-implementations: NOT CHECKED (exit 3) -- {exc}", file=sys.stderr)
        print("  This is NOT a pass. An address that could not be asked about is not an "
              "address that is published.", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
