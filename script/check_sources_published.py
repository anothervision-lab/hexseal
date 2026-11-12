#!/usr/bin/env python3
"""
Gate: every contract of the LIVE protocol has its source published on the
block explorer.

Run it through ./script/check-sources-published.sh (that wrapper checks the
working directory and the tools).

---------------------------------------------------------------------------
WHY IT EXISTS

Twice in two days, and three times before that, the fact that a deployed
contract was NOT verified arrived as a question from the owner rather than
from a check:

  * 21 Aug 2026 -- the cut ran with `--verify`, the script died on a receipt
    BEFORE verification, and three contracts stayed unverified
    (the open-items log, item 109);
  * 14 Sep 2026 -- 4 of the 14 mounted facets were unverified, one of them
    since 25 July. Three months, three cuts, and nothing in this repository
    looked;
  * 19 and 20 Sep 2026 -- three more, then two more. Published by hand, after
    a comment in a deploy script happened to remind somebody.

Verification is not decoration. The protocol's claim is that it is autonomous,
and the only way a stranger can check that claim is to open the contract and
read the source. An unverified facet is that promise taken on trust.

Nothing counted them, so the tail accumulated in silence. This gate counts.

---------------------------------------------------------------------------
WHERE THE ROSTER COMES FROM -- THE CHAIN, NOT A LIST IN THIS FILE

⚠️ There is no list of addresses here, and that is the point. A hardcoded
roster is the thing that goes stale silently: it keeps passing while the
contract it names is three cuts behind the one that is actually running.

Exactly ONE address is a literal, and it cannot be anything else -- the
traversal has to start somewhere. It is the diamond proxy, which is the one
address in this system that never changes -- the standing rule of this project
is that the diamond's proxy address never changes, while everything else on
chain changes with every upgrade.
Even that is not written here: it is read from the committed censuses in
test/fixtures/chain-*-selectors.json, ALL of which must agree on it, or this
gate exits 2. Fourteen files agreeing is a harder thing to get wrong by hand
than one literal.

From that root everything else is a READ, not an entry:

    diamond.facetAddresses()          -> every mounted facet
    diamond.getAgreementDeployer()    -> AgreementDeployer
      deployer.implementation()       -> the Agreement implementation
        implementation.RENDERER()     -> AgreementRenderer
    diamond.getSvgRenderer()          -> SVGRenderer (job receipts)
    diamond.getTrustedForwarder()     -> MinimalForwarder
    diamond.getFeeRecipient()         -> ProtocolTreasury

The table below is a table of CALLS. Add a facet, swap an implementation,
re-seat the treasury -- the roster follows by itself, because it is the chain's
answer and not ours.

⚠️ WHERE THE EXPECTED SIDE COMES FROM. The chain says which addresses; the
explorer says whether each one is published. Neither side is derived from this
repository, so this gate cannot agree with itself the way a stand does when its
expectation is computed from the thing under test. The committed census is used
for ONE thing only -- putting a human-readable NAME next to an address -- and a
name can never change the verdict: an address the census has never heard of is
still queried, still counted, and still turns this gate red if it is unpublished.

---------------------------------------------------------------------------
WHAT IS DELIBERATELY NOT ON THE ROSTER, AND WHY

  * USDC (`diamond.getUsdc()`). Circle's contract, not ours. Whether Circle
    publishes their source is not a thing this repository can fix or should
    report on.
  * The DAO address, the owner, the foundation. Externally owned accounts, or
    zero until a handover. There is no source behind an EOA to publish.
  * Deal clones. EIP-1167 minimal proxies, one per deal, and their source IS
    the implementation -- which IS on the roster. Querying thousands of clones
    would cost thousands of explorer calls to re-learn one answer.
  * Contracts that were replaced. The retired Treasury at 0x2e7a7A05, every
    superseded implementation, every unmounted facet. They are no longer part
    of the live protocol; the roster is what is RUNNING, which is the thing the
    promise is about. (A retired facet stays verified anyway -- publication is
    not undone by unmounting.)

---------------------------------------------------------------------------
WHAT THIS GATE DOES NOT CATCH

"Published" is not "the same as this tree". The explorer answers a narrower
question: is there a source behind this address at all. It does not answer
whether that source is the source in `src/` at the commit you are standing on.
The measured reason it cannot be conflated with that: on 14 Sep 2026
DiamondLoupeFacet's runtime body matched the tree byte for byte and the
explorer still refused to verify it from the tree, because it compares
deployment bytecode WITH metadata, and the metadata carries the solc version
from the CBOR tail (0.8.30 there, 0.8.31 pinned here) and the absolute build
path of the machine that compiled it.

That other question -- does the chain run this tree -- is a codehash
comparison, and it is a different check. This one is about the promise being
keepable at all: you cannot compare a source nobody can read.

It also does not catch: a contract deployed and never wired in (nothing on the
chain points at it, so nothing can find it); verification of a PROXY's
implementation as opposed to the proxy (the diamond is not an EIP-1967 proxy
and the explorer's `Implementation` field is empty for it); and anything the
explorer's `getsourcecode` reports wrongly.

---------------------------------------------------------------------------
"COULD NOT CHECK" IS NOT "CLEAN"

The whole value of this gate is that it is the thing that remembers. A gate
that goes quiet when the key is missing is worse than no gate at all: it puts a
green tick next to a question nobody asked. So there are four separate answers,
and only one of them is a pass:

    0   every contract on the roster is published
    1   at least one is NOT -- named, with its address and how it was found
    2   the inputs are damaged (no census, or the censuses disagree about the
        diamond). Nothing was measured.
    3   COULD NOT MEASURE -- no API key, no network, the explorer refused or
        rate-limited, or a chain read failed. Nothing was measured.

⚠️ An address that reads back as zero, or that has no code, does NOT become a
"not published" finding. It becomes exit 3, because the roster could not be
assembled and a missing entry would otherwise be skipped in silence -- which is
the whole class of accident this gate was written against. The one exception is
the fee recipient, which is allowed to be an ordinary account: a person can
legitimately be paid the fee, and there is no source behind a person. That is
reported as a note and does not colour the exit code.

---------------------------------------------------------------------------
THE KEY

Read from ETHERSCAN_API_KEY or BASESCAN_API_KEY in the environment, falling
back to the same names in ./.env. Its VALUE is never printed -- not in the
report, not in an error, not in the URL echoed on failure. Only derived facts
("set", "not set", which name it came from). A house rule of this project.

⚠️ The v1 endpoint (api-sepolia.basescan.org) is deprecated and answers NOTOK.
The multichain v2 endpoint with chainid=84532 is the one that answers.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

CHAIN_ID = "84532"
EXPLORER = "https://api.etherscan.io/v2/api"
DEFAULT_RPC = "https://sepolia.base.org"
CENSUS_GLOB = "test/fixtures"
CENSUS_RE = re.compile(r"^chain-\d{4}-\d{2}-\d{2}-.*-selectors\.json$")

# Explorer free tier is 5 calls/second. 0.25 s between calls keeps us under
# half of that even if every call returned instantly, which they do not.
UA = "hexseal-check-sources-published/1.0"
PAUSE = 0.25
HTTP_TIMEOUT = 25
RETRIES = 2

# ── The roster, written as CALLS and not as addresses ───────────────────────
#
# Each row: (label, called-on, signature, eoa_ok). `called-on` is the key of an
# address discovered by an earlier row, or "diamond" for the root. The order is
# the traversal order and the chain of reads is literal: break any link and the
# gate says which link broke.
OFF_DIAMOND = [
    ("AgreementDeployer",  "diamond",            "getAgreementDeployer()(address)", False),
    ("Agreement impl",     "AgreementDeployer",  "implementation()(address)",       False),
    ("AgreementRenderer",  "Agreement impl",     "RENDERER()(address)",             False),
    ("SVGRenderer",        "diamond",            "getSvgRenderer()(address)",       False),
    ("MinimalForwarder",   "diamond",            "getTrustedForwarder()(address)",  False),
    ("ProtocolTreasury",   "diamond",            "getFeeRecipient()(address)",      True),
]

ZERO = "0x" + "0" * 40


class Damaged(Exception):
    pass


class Unmeasurable(Exception):
    pass


def api_key():
    """(key, which-name) or (None, None). The value never leaves this function
    except as the `apikey` query parameter."""
    for name in ("ETHERSCAN_API_KEY", "BASESCAN_API_KEY"):
        v = os.environ.get(name, "").strip()
        if v:
            return v, f"{name} (environment)"
    if os.path.isfile(".env"):
        try:
            for raw in open(".env", encoding="utf-8", errors="replace"):
                line = raw.strip()
                if line.startswith("export "):
                    line = line[7:].strip()
                for name in ("ETHERSCAN_API_KEY", "BASESCAN_API_KEY"):
                    if line.startswith(name + "="):
                        v = line[len(name) + 1:].strip().strip('"').strip("'")
                        if v:
                            return v, f"{name} (.env)"
        except OSError:
            pass
    return None, None


def diamond_from_censuses():
    """The one literal in the traversal, and it is not written here. Every
    committed census must name the same diamond; disagreement is damage, not a
    tie to be broken by picking the newest."""
    if not os.path.isdir(CENSUS_GLOB):
        raise Damaged(f"{CENSUS_GLOB}/ is missing: no census to take the diamond from")
    seen = {}
    for fn in sorted(os.listdir(CENSUS_GLOB)):
        if not CENSUS_RE.match(fn):
            continue
        path = os.path.join(CENSUS_GLOB, fn)
        try:
            j = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise Damaged(f"{path}: {exc}")
        addr = j.get("diamond")
        if not addr:
            raise Damaged(f"{path}: no `diamond` field")
        seen.setdefault(addr, []).append(fn)
    if not seen:
        # An empty result reading as a pass is exactly how this class of check
        # dies. It is damage.
        raise Damaged(f"no chain-*-selectors.json under {CENSUS_GLOB}/")
    if len({a.lower() for a in seen}) > 1:
        lines = "; ".join(f"{a} in {len(f)} file(s), e.g. {f[0]}" for a, f in seen.items())
        raise Damaged("the committed censuses disagree about the diamond proxy, "
                      "which never changes: " + lines)
    addr = sorted(seen)[0]
    return addr, sum(len(f) for f in seen.values())


def newest_census():
    """byFacet, used ONLY to put a name next to an address. Never used to
    decide which addresses exist."""
    best = None
    for fn in sorted(os.listdir(CENSUS_GLOB)):
        if CENSUS_RE.match(fn):
            best = fn
    if not best:
        return {}, None, None
    j = json.load(open(os.path.join(CENSUS_GLOB, best), encoding="utf-8"))
    names = {e["facet"].lower(): e.get("name", "?") for e in j.get("byFacet", [])}
    return names, best, j.get("takenAt")


def cast_call(rpc, to, sig):
    p = subprocess.run(["cast", "call", to, sig, "--rpc-url", rpc],
                       capture_output=True, text=True)
    if p.returncode != 0:
        why = (p.stderr.strip() or p.stdout.strip() or "no output").splitlines()[0]
        raise Unmeasurable(f"`cast call {to} {sig}` exited {p.returncode}: {why[:200]}")
    out = p.stdout.strip()
    if not out:
        raise Unmeasurable(f"`cast call {to} {sig}` returned nothing")
    return out


def codes(rpc, addrs):
    """One batched eth_getCode for the whole roster. Batched because 21 separate
    round trips to a public endpoint is 21 chances for a flake, and a flake here
    would read as "this address has no code"."""
    body = [{"jsonrpc": "2.0", "id": i, "method": "eth_getCode",
             "params": [a, "latest"]} for i, a in enumerate(addrs)]
    req = urllib.request.Request(
        rpc, data=json.dumps(body).encode(),
        # ⚠️ User-Agent is load-bearing. Measured: the public Base Sepolia
        # endpoint answers curl and returns HTTP 403 to urllib's default
        # `Python-urllib/3.x`, and a 403 here would read as "could not measure"
        # on every run -- a gate permanently the colour of a broken gate.
        headers={"content-type": "application/json", "user-agent": UA},
        method="POST")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            data = json.loads(r.read().decode())
    except (urllib.error.URLError, ValueError, OSError) as exc:
        raise Unmeasurable(f"eth_getCode batch against {rpc} failed: {exc}")
    if not isinstance(data, list) or len(data) != len(addrs):
        raise Unmeasurable(f"eth_getCode batch against {rpc} answered something unparseable")
    out = {}
    for e in data:
        i = e.get("id")
        if not isinstance(i, int) or "result" not in e:
            raise Unmeasurable(f"eth_getCode batch: {str(e)[:150]}")
        out[addrs[i].lower()] = e["result"] or "0x"
    return out


def published(addr, key):
    """(state, detail). state is one of 'yes', 'no'. Anything else raises
    Unmeasurable -- the explorer being unable to answer is never a 'no'."""
    q = urllib.parse.urlencode({
        "chainid": CHAIN_ID, "module": "contract",
        "action": "getsourcecode", "address": addr, "apikey": key})
    last = None
    for attempt in range(RETRIES + 1):
        try:
            req = urllib.request.Request(f"{EXPLORER}?{q}", headers={"user-agent": UA})
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
                d = json.loads(r.read().decode())
        except (urllib.error.URLError, ValueError, OSError) as exc:
            last = f"{type(exc).__name__}: {exc}"
            time.sleep(PAUSE * (attempt + 2))
            continue
        if str(d.get("status")) == "1" and isinstance(d.get("result"), list) and d["result"]:
            e = d["result"][0]
            name = (e.get("ContractName") or "").strip()
            src = e.get("SourceCode") or ""
            if name and src:
                return "yes", f"{name}, {e.get('CompilerVersion') or 'compiler unknown'}"
            return "no", "the explorer has no source for this address"
        # status 0 is the explorer refusing, never a verdict about the contract.
        msg = str(d.get("result") or d.get("message") or d)[:200]
        last = f"explorer refused: {msg}"
        if "rate limit" in msg.lower():
            time.sleep(1.2)
            continue
        break
    raise Unmeasurable(f"could not ask the explorer about {addr} -- {last}")


def main() -> int:
    rpc = os.environ.get("RPC_URL", DEFAULT_RPC)
    started = time.time()

    key, key_from = api_key()
    if not key:
        print("check-sources-published: NOT CHECKED (exit 3) -- no explorer API key.", file=sys.stderr)
        print("  Looked for ETHERSCAN_API_KEY and BASESCAN_API_KEY in the environment", file=sys.stderr)
        print("  and in ./.env. Neither is set.", file=sys.stderr)
        print("  This is NOT a pass. Nothing was asked and nothing was measured.", file=sys.stderr)
        return 3

    try:
        diamond, n_census = diamond_from_censuses()
    except Damaged as exc:
        print(f"check-sources-published: DAMAGED (exit 2) -- {exc}", file=sys.stderr)
        print("  Nothing was measured.", file=sys.stderr)
        return 2
    names, census_file, taken = newest_census()

    print(f"explorer key: set, from {key_from}")
    print(f"rpc         : {rpc}")
    print(f"root        : {diamond} (agreed by {n_census} committed census file(s))")
    print()

    # ── assemble the roster from the chain ──────────────────────────────────
    roster = []      # (label, address, how)
    found = {"diamond": diamond}
    notes = []
    try:
        raw = cast_call(rpc, diamond, "facetAddresses()(address[])")
        facets = re.findall(r"0x[0-9a-fA-F]{40}", raw)
        if not facets:
            raise Unmeasurable(
                "facetAddresses() answered without a single address: " + raw[:200])
        roster.append(("DiamondProxy", diamond, "the root"))
        for a in facets:
            label = names.get(a.lower())
            if label is None:
                label = "facet UNKNOWN TO THE CENSUS"
                notes.append(f"{a} is mounted but is not in {census_file} "
                             f"(taken {taken}) -- checked anyway, named by the explorer below")
            roster.append((label, a, "diamond.facetAddresses()"))

        for label, on, sig, _eoa_ok in OFF_DIAMOND:
            base = found.get(on)
            if base is None:
                raise Unmeasurable(
                    f"cannot read {sig} for {label}: the address of {on} was never found")
            got = cast_call(rpc, base, sig).strip().split()[0]
            if not re.fullmatch(r"0x[0-9a-fA-F]{40}", got):
                raise Unmeasurable(f"{on}.{sig} answered {got[:80]!r}, which is not an address")
            if got.lower() == ZERO:
                raise Unmeasurable(f"{on}.{sig} answered the zero address")
            found[label] = got
            roster.append((label, got, f"{on}.{sig.split('(')[0]}()"))

        code = codes(rpc, [a for _l, a, _h in roster])
    except Unmeasurable as exc:
        print(f"check-sources-published: NOT CHECKED (exit 3) -- could not assemble", file=sys.stderr)
        print(f"  the roster from the chain: {exc}", file=sys.stderr)
        print("  This is NOT a pass. An address that could not be reached is an address", file=sys.stderr)
        print("  nobody asked about, which is exactly what this gate exists to stop.", file=sys.stderr)
        return 3

    eoa_ok = {l for l, _o, _s, ok in OFF_DIAMOND if ok}
    skipped = []
    for label, addr, how in list(roster):
        if len(code.get(addr.lower(), "0x")) > 2:
            continue
        if label in eoa_ok:
            skipped.append((label, addr, how))
            roster = [r for r in roster if r[1] != addr]
            continue
        print(f"check-sources-published: NOT CHECKED (exit 3) -- {label} at {addr}",
              file=sys.stderr)
        print(f"  (found by {how}) has no code on chain. The roster is wrong, and a", file=sys.stderr)
        print("  wrong roster silently checks the wrong set. Nothing is reported as clean.",
              file=sys.stderr)
        return 3

    # ── ask the explorer about every address ────────────────────────────────
    bad, good = [], []
    try:
        for i, (label, addr, how) in enumerate(roster):
            if i:
                time.sleep(PAUSE)
            state, detail = published(addr, key)
            (good if state == "yes" else bad).append((label, addr, how, detail))
    except Unmeasurable as exc:
        print(f"check-sources-published: NOT CHECKED (exit 3) -- {exc}", file=sys.stderr)
        print("  This is NOT a pass. Some of the roster was never asked about.", file=sys.stderr)
        if bad:
            print(f"  ({len(bad)} unpublished contract(s) had already been found before"
                  f" the explorer stopped answering -- see above.)", file=sys.stderr)
        return 3

    took = time.time() - started
    for label, addr, _how, detail in good:
        shown = detail.split(",")[0]
        tag = f"{label}" if label.startswith("facet ") or shown == label else f"{label} [{shown}]"
        print(f"  published  {addr}  {tag}")
    for label, addr, how, _d in skipped:
        print(f"  no code    {addr}  {label} (found by {how}) -- an ordinary account, "
              f"nothing to publish")
    for n in notes:
        print(f"  note       {n}")

    print()
    if bad:
        print(f"{len(bad)} of {len(roster)} live contract(s) have NO published source:")
        for label, addr, how, _d in bad:
            print(f"  * {label}")
            print(f"      {addr}")
            print(f"      found by {how}")
            print(f"      https://sepolia.basescan.org/address/{addr}#code")
        print()
        print("  Publish them, then re-run. `forge verify-contract` needs the artifact of")
        print("  the SAME solc the contract was built with -- the version is in the CBOR")
        print("  tail on chain, not in foundry.toml. The open-items log, item 109,")
        print("  records what makes this hard and the trick that works (verify from")
        print("  the standard-json of a neighbour published in the same trip).")
        print(f"\n  checked {len(roster)} address(es) in {took:.1f} s.", file=sys.stderr)
        return 1

    print(f"OK: all {len(roster)} live contract(s) of the protocol have a published source.")
    print(f"    {len(roster) - len(OFF_DIAMOND) + len(skipped) - 1} mounted facet(s) + the proxy"
          f" + {len(OFF_DIAMOND) - len(skipped)} contract(s) outside the diamond,"
          f" in {took:.1f} s.")
    print("    (This gate compared the CHAIN with the EXPLORER. Whether the published")
    print("     source is the source in this tree is a codehash question and a separate")
    print("     answer -- see the docstring.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
