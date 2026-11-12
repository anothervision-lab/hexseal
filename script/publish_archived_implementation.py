#!/usr/bin/env python3
"""Rebuild an Agreement implementation whose source has left the tree, and
publish it -- but only behind an oracle that compares the rebuild with OUR OWN
byte record of the deployment.

Run it through ./script/publish-archived-implementation.sh (that wrapper checks
the working directory and the tools).

---------------------------------------------------------------------------
WHAT THIS IS FOR

An EIP-1167 clone carries its implementation's address inside its own body and
never changes it, so every swap of the implementation leaves one more
generation of deals running the old one for ever. The gate
script/check-clone-implementations.sh walks from the registry to the clones and
from each clone to the body it executes, and asks the explorer whether that
body has a published source. On 31 October 2026 it answered: sixteen deals,
seven distinct bodies, six published, ONE NOT -- and that one is executing a
real deal. Its source is not in today's tree; it was compiled in July 2026 by a
different compiler, under settings this repository has since deliberately
changed.

The owner's decision of that day (item 250 of the decision log) says a body
executing at least one live deal must have a published source, INCLUDING a body
whose source is no longer in the tree. This script is that repair, made
repeatable.

---------------------------------------------------------------------------
THE LABEL LIES, THE BYTES DO NOT

`forge` writes the git commit into its own broadcast record. For this
deployment it wrote `a916d1f`, and that object does not exist in this
repository at all -- not as a commit, not as anything (`git cat-file -t` says
"not a valid object name"). Three history rewrites happened here in August
2026. So the one field that was supposed to say WHICH SOURCE was deployed is
unusable.

What is usable is the deployment's own input. The same broadcast record holds
the CREATE transaction's calldata, and `Agreement`'s constructor takes no
arguments -- so that calldata IS the creation code, with nothing appended and
nothing to mask. Two independent checks tie it to the live chain:

  * the last 20_545 bytes of the recorded 20_590 ARE the body the chain
    returns for that address today, byte for byte (the first 45 bytes are the
    constructor);
  * the metadata tail of both ends `...64736f6c634300081e 0033` -- 53 bytes,
    solc 0.8.30, the old form WITH the source hash, i.e. compiled before
    `bytecode_hash = "none"` entered foundry.toml.

So the candidate commit is a GUESS and the recorded bytes are the JUDGE. This
script is built around that asymmetry: it proposes a commit, prints its
argument for it, and then refuses to publish anything unless the rebuild equals
the record byte for byte, whole.

---------------------------------------------------------------------------
WHY THE COMPILE IS NOT RUN FROM HERE, AND WHY IT IS A `solc` CALL

Two separate reasons, both measured rather than assumed.

THE COST. A full `via_ir` compilation of this tree peaks at about 12 GB and
takes longer than any single tool call may run. That has already cost this
project three executors lost mid-work. So the compile is handed to the owner as
ONE READY LINE, and everything else in this script -- finding the record,
deriving the candidate, the oracle, the publication, the verdict -- works from
an artifact whose path is an ARGUMENT. Both branches of the oracle are
therefore provable by substitution, with no compile at all, and that is the
acceptance for this script.

THE SHAPE. The rebuild is a `solc --standard-json` call on the ONE file this
contract needs, not a `forge build`, and that is not a preference either:

  * at the candidate commit `src/Agreement.sol` has NO imports -- the
    deployment's own metadata lists exactly one source -- so the compilation
    unit is a single file and does not need the project at all;
  * `settings.remappings` goes into the metadata JSON, the metadata JSON is
    what the IPFS hash in the tail covers, and the remappings list depends on
    the FORGE version. Measured in the archived tree: forge 1.8.1 emits SIX
    remappings there, including a context entry `lib/openzeppelin-contracts/:
    forge-std/=...` that the original build's metadata does not contain. A
    `forge build` of that commit today therefore cannot reproduce the tail,
    however correct the source is. A standard-json input states the five
    recorded remappings and is independent of the forge version and of where
    the tree happens to sit on disk.

`solc` normalises a remapping with no context to a leading `:` either way
(measured, both input forms, solc 0.8.30), so the recorded strings can be
passed through verbatim.

---------------------------------------------------------------------------
THE VERDICT IS THE WATCHDOG'S, NOT THE BUILDER'S

`forge verify-contract` asks two verifiers and prints the tail of one of them;
its exit status is 0 almost always. So "published" is never concluded from the
submission's own answer here. Publication is a request; the VERDICT is a
separate reading: check-clone-implementations.sh is run again afterwards and
its exit code decides. The explorer accepting a source and queueing it is a
third state, and it gets its own exit code rather than being rounded up to
success -- see EXIT CODES below.

---------------------------------------------------------------------------
WHAT THIS DOES NOT DO

  * It never writes to the chain. The only network traffic is: one read of the
    deployed code (skippable), the explorer requests, and whatever the watchdog
    does.
  * It does not touch the working tree. The archived commit is extracted with
    `git archive` into a directory of its own; no worktree (worktrees break
    this project's tooling) and no checkout.
  * It cannot materialise submodules. At the commit this was written for, lib/
    was still vendored as ordinary files -- submodules arrived on 15 August
    2026 -- so `git archive` carries everything. If the candidate commit has a
    .gitmodules, this script prints the pins and refuses rather than silently
    extracting a tree with empty library directories.
  * It proves nothing about the source matching the bytes for any OTHER
    address. One address per run, named on the command line.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# The explorer's v2 endpoint and this chain. Same two constants the publication
# gate next door uses, and for the same reason: one copy of each.
CHAIN_ID = "84532"
EXPLORER = "https://api.etherscan.io/v2/api"
DEFAULT_RPC = "https://sepolia.base.org"
UA = "hexseal-publish-archived-implementation/1.0"
HTTP_TIMEOUT = 30
POLL_PAUSE = 5.0
POLL_TRIES = 6

# Exit codes. Every one of them is a different answer, and none of them is
# rounded towards success.
OK = 0
DAMAGED = 2          # nothing was measured: no record, several records, submodules
UNMEASURABLE = 3     # could not ask / could not read -- NOT a pass
MISMATCH = 4         # THE ORACLE SAID NO. The rebuild is not these bytes.
REFUSED = 5          # the explorer rejected the source
UNREACHABLE = 6      # the explorer could not be reached or rate-limited us
PENDING = 7          # the explorer took the source and has NOT verified it yet
CONTRADICTED = 8     # the explorer said "verified", the watchdog says otherwise


# ── HOW MUCH OF A HEX DUMP IS EVER PRINTED ───────────────────────────────────
#
# ⚠️ CUT BY WHAT IS PRINTED, NEVER BY WHAT THE BYTES DECLARE. Measured
# 31 October 2026 on a build output one byte short: the declared tail length is
# then read out of two truncated bytes and comes back as 7682, so the dump went
# out as ONE LINE OF 15_397 CHARACTERS and the verdict drowned in it. A refusal
# nobody can read is a refusal nobody acts on, and the reader here is the owner
# in his own terminal.
TAIL_DUMP_BYTES = 64
LINE_WIDTH = 100


def clip_hex(h, keep=TAIL_DUMP_BYTES):
    """A hex dump cut to `keep` bytes, saying how many it dropped."""
    if h is None:
        return "none"
    if len(h) <= keep * 2:
        return h
    return f"{h[:keep * 2]}… +{len(h) // 2 - keep} more byte(s), not printed"


def say(text, indent="      ", stream=None):
    """Prose, wrapped. Long single-line warnings are how a verdict gets lost."""
    import textwrap
    for line in textwrap.wrap(text, width=LINE_WIDTH,
                              initial_indent=indent, subsequent_indent=indent):
        print(line, file=stream or sys.stdout)


class Damaged(Exception):
    pass


class Unmeasurable(Exception):
    pass


# --------------------------------------------------------------------------
# the record


def find_snapshot(address: str):
    """Our own byte record of this deployment, found BY ADDRESS.

    The path is not an argument and not a literal in here: a snapshot named by
    hand is a snapshot that can be pointed at the wrong deployment. Every
    `broadcast/<Script>/<chain>/run-*.json` is read and the CREATE whose
    contractAddress is this address is the one. Several files hold the same run
    (`run-latest.json` is a copy of the newest `run-<ms>.json`), so matches are
    de-duplicated by the transaction's own input.
    """
    addr = address.lower()
    hits = []
    for root, _dirs, files in os.walk("broadcast"):
        if os.path.basename(root) != CHAIN_ID:
            continue
        for name in sorted(files):
            if not (name.startswith("run-") and name.endswith(".json")):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, encoding="utf-8") as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            for tx in doc.get("transactions") or []:
                if (tx.get("contractAddress") or "").lower() != addr:
                    continue
                if (tx.get("transactionType") or "").upper() != "CREATE":
                    raise Damaged(
                        f"{path} holds {addr} as a "
                        f"{tx.get('transactionType')}, not a CREATE")
                hits.append((path, doc, tx))
    if not hits:
        raise Damaged(
            f"no broadcast record of ours deploys {address} on chain {CHAIN_ID}. "
            "Without our own bytes there is nothing for the oracle to compare "
            "against, and this script will not guess.")
    codes = {code_of(tx) for _p, _d, tx in hits}
    if len(codes) != 1:
        raise Damaged(
            f"{len(hits)} broadcast records deploy {address} and they do not "
            "agree on the creation code: " +
            ", ".join(p for p, _d, _t in hits))
    return hits[0], [p for p, _d, _t in hits]


def code_of(tx) -> str:
    """The creation code out of a broadcast transaction, lowercase, no 0x."""
    inner = tx.get("transaction") or {}
    raw = inner.get("input") or inner.get("data") or ""
    if not raw.startswith("0x") or len(raw) < 4:
        raise Damaged("the broadcast record holds no creation code")
    if inner.get("to"):
        raise Damaged(
            "the broadcast record's transaction has a `to` -- that is a call, "
            "not a deployment")
    return raw[2:].lower()


def tail_info(code: str) -> dict:
    """The metadata tail, with its length READ OUT OF THE TAIL ITSELF.

    The house rule, and it has one owner for a measured reason: this tree
    carries both lengths at once. An artifact built today ends with 12 bytes
    (`bytecode_hash = "none"`, CBOR `{"solc": ...}`); six of the fifteen bodies
    live on chain end with 53, because they were deployed before that setting
    changed. Any instrument that writes either number down is wrong about the
    other half.
    """
    out = {"declared": None, "tail": None, "solc": None, "has_ipfs": None}
    if len(code) < 4:
        return out
    n = int(code[-4:], 16) + 2
    if n <= 0 or n * 2 > len(code):
        return out
    tail = code[-n * 2:]
    out["declared"] = n
    out["tail"] = tail
    out["has_ipfs"] = "64697066735822" in tail      # CBOR key "ipfs", 34 bytes
    m = re.search(r"64736f6c6343([0-9a-f]{6})", tail)   # "solc" + 3 bytes
    if m:
        out["solc"] = "%d.%d.%d" % tuple(int(m.group(1)[i:i + 2], 16)
                                         for i in (0, 2, 4))
    return out


def deploy_moment(doc) -> tuple:
    """(epoch seconds, note). forge writes MILLISECONDS here."""
    ts = doc.get("timestamp")
    if not isinstance(ts, (int, float)):
        raise Damaged("the broadcast record has no timestamp")
    if ts > 1e12:
        return int(ts // 1000), "milliseconds (forge's unit here)"
    return int(ts), "seconds"


# --------------------------------------------------------------------------
# the chain, read-only


def chain_code(address: str, rpc: str) -> str:
    try:
        p = subprocess.run(["cast", "code", address, "--rpc-url", rpc],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Unmeasurable(f"`cast code` could not run: {exc}")
    if p.returncode != 0:
        raise Unmeasurable(
            f"`cast code {address}` exited {p.returncode}: "
            f"{(p.stderr or '').strip()[:200]}")
    out = (p.stdout or "").strip()
    if not out.startswith("0x") or len(out) < 4:
        raise Unmeasurable(f"`cast code {address}` answered {out[:40]!r}")
    return out[2:].lower()


def keccak(data: bytes) -> str:
    """keccak256 through `cast`, which this repository already depends on.

    Hashing by hand would mean carrying a keccak implementation in here, which
    is exactly the kind of second copy these scripts exist to avoid.
    """
    try:
        p = subprocess.run(["cast", "keccak"], input=data,
                           capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Unmeasurable(f"`cast keccak` could not run: {exc}")
    if p.returncode != 0:
        raise Unmeasurable(f"`cast keccak` exited {p.returncode}")
    return p.stdout.decode().strip().lower()


# --------------------------------------------------------------------------
# the candidate commit


def git(*args, binary=False):
    p = subprocess.run(["git"] + list(args), capture_output=True, timeout=120)
    if p.returncode != 0:
        raise Unmeasurable(
            f"`git {' '.join(args[:3])}` exited {p.returncode}: "
            f"{p.stderr.decode(errors='replace').strip()[:200]}")
    return p.stdout if binary else p.stdout.decode(errors="replace")


def object_exists(rev: str) -> bool:
    p = subprocess.run(["git", "cat-file", "-t", rev],
                       capture_output=True, timeout=60)
    return p.returncode == 0


def source_path_of(contract: str) -> str:
    """Where `<Contract>.sol` lives, asked of git rather than of the disk, so a
    file that has since been moved or deleted is still found."""
    for rev in ("HEAD",):
        names = git("ls-tree", "-r", "--name-only", rev).splitlines()
        for n in names:
            if n.endswith(f"/{contract}.sol") or n == f"src/{contract}.sol":
                return n
    hits = set()
    for line in git("log", "--all", "--pretty=format:", "--name-only",
                    "--diff-filter=A").splitlines():
        if line.endswith(f"/{contract}.sol"):
            hits.add(line)
    if len(hits) == 1:
        return hits.pop()
    raise Damaged(
        f"cannot tell which file holds contract {contract}: "
        f"{sorted(hits) or 'no candidate'}")


def candidate_commit(path: str, at_epoch: int) -> dict:
    """The last commit that touched `path` at or before the deployment, plus
    the argument for it, printed rather than implied.

    Timestamps are a WEAK argument and this says so: they establish an order,
    not an identity. The strong one comes later and for free -- the metadata of
    the rebuild names the keccak256 of every source it compiled, and that hash
    is matched against the candidate's own tree (`cross_check_sources`).
    """
    out = {"path": path, "at": at_epoch}
    rows = [r for r in git("log", "--format=%H|%ct|%ci", "--", path).splitlines()
            if r.strip()]
    chosen = None
    for row in rows:
        h, ct, ci = row.split("|", 2)
        if int(ct) <= at_epoch:
            chosen = (h, int(ct), ci)
            break
    if chosen is None:
        raise Damaged(f"no commit touches {path} at or before the deployment")
    out["commit"], out["commit_epoch"], out["commit_date"] = chosen

    head = None
    for row in git("log", "--format=%H|%ct|%ci").splitlines():
        h, ct, ci = row.split("|", 2)
        if int(ct) <= at_epoch:
            head = (h, int(ct), ci)
            break
    out["head_at_deploy"] = head[0] if head else None
    out["head_date"] = head[2] if head else None

    if head and head[0] != out["commit"]:
        between = git("diff", "--name-only", out["commit"], head[0]).splitlines()
        out["changed_between"] = [b for b in between if b.strip()]
    else:
        out["changed_between"] = []
    return out


# --------------------------------------------------------------------------
# the isolated tree and the compiler input


def materialise(commit: str, work_dir: str) -> str:
    """`git archive` the commit into a directory of its own.

    Not a worktree: worktrees break this project's test tooling, and this needs
    nothing a worktree would give. Not the working tree either -- that belongs
    to whoever is using it.
    """
    gm = subprocess.run(["git", "cat-file", "-e", f"{commit}:.gitmodules"],
                        capture_output=True, timeout=60)
    if gm.returncode == 0:
        pins = [l for l in git("ls-tree", commit, "lib/").splitlines() if l.strip()]
        raise Damaged(
            "the candidate commit has submodules, and `git archive` cannot "
            "carry a submodule's contents. Materialising those pins is not "
            "implemented here, so nothing was extracted. The pins are:\n  " +
            "\n  ".join(pins))
    os.makedirs(work_dir, exist_ok=True)
    if os.listdir(work_dir):
        raise Damaged(f"{work_dir} is not empty; refusing to extract into it")
    tar = subprocess.Popen(["git", "archive", commit],
                           stdout=subprocess.PIPE)
    un = subprocess.Popen(["tar", "-x", "-C", work_dir], stdin=tar.stdout)
    tar.stdout.close()
    un.communicate()
    if un.returncode != 0 or tar.wait() != 0:
        raise Unmeasurable(f"extracting {commit} into {work_dir} failed")
    return work_dir


IMPORT_RE = re.compile(r"""^\s*import\s+(?:[^"';]*?\bfrom\s*)?["']([^"']+)["']""",
                       re.MULTILINE)


def closure(root: str, entry: str, remappings: list) -> list:
    """Every file the compiler will need for `entry`, found by following its
    imports. A file this misses makes `solc` fail loudly with "source not
    found" -- it cannot make the rebuild quietly wrong.
    """
    pairs = []
    for r in remappings:
        body = r.split(":", 1)[1] if ":" in r.split("=", 1)[0] else r
        if "=" in body:
            pre, tgt = body.split("=", 1)
            pairs.append((pre, tgt))
    seen, queue = [], [entry]
    while queue:
        rel = queue.pop(0)
        if rel in seen:
            continue
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            raise Damaged(f"{rel} is imported but not present in the archived tree")
        seen.append(rel)
        text = open(full, encoding="utf-8", errors="replace").read()
        for target in IMPORT_RE.findall(text):
            if target.startswith("."):
                nxt = os.path.normpath(os.path.join(os.path.dirname(rel), target))
            else:
                nxt = target
                for pre, tgt in pairs:
                    if target.startswith(pre):
                        nxt = tgt + target[len(pre):]
                        break
            queue.append(nxt.replace(os.sep, "/"))
    return seen


def settings_from(path: str) -> tuple:
    """Compiler settings lifted from a RECORDED build, with where each came
    from. A forge artifact, or a metadata JSON, or solc's own output.

    These are inputs, not expectations: nothing but the solc version can be
    read off the deployed bytes, so the optimizer, the evm version and the
    remappings have to come from somewhere, and a build that this machine
    actually performed is a better somewhere than a literal. What certifies the
    whole set is the oracle, which compares against the broadcast record and
    knows nothing about this file.
    """
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    meta = None
    if isinstance(doc.get("metadata"), dict):
        meta = doc["metadata"]
    elif isinstance(doc.get("rawMetadata"), str):
        meta = json.loads(doc["rawMetadata"])
    elif "settings" in doc and "compiler" in doc:
        meta = doc
    if meta is None:
        raise Damaged(f"{path} carries no compiler metadata")
    s = meta.get("settings") or {}
    return {
        "solc": (meta.get("compiler") or {}).get("version"),
        "optimizer": s.get("optimizer") or {"enabled": True, "runs": 200},
        "viaIR": bool(s.get("viaIR")),
        "evmVersion": s.get("evmVersion"),
        "bytecodeHash": (s.get("metadata") or {}).get("bytecodeHash", "ipfs"),
        "libraries": s.get("libraries") or {},
        "remappings": list(s.get("remappings") or []),
        "sources": meta.get("sources") or {},
        "target": s.get("compilationTarget") or {},
    }, f"recorded build metadata in {path}"


def settings_fallback(root: str, solc_from_tail: str) -> tuple:
    """Settings derived from the archived foundry.toml when no recorded build
    is available -- and LOUD about the one it cannot derive."""
    toml = os.path.join(root, "foundry.toml")
    text = open(toml, encoding="utf-8", errors="replace").read() if os.path.isfile(toml) else ""
    runs = re.search(r"^\s*optimizer_runs\s*=\s*(\d+)", text, re.MULTILINE)
    via = re.search(r"^\s*via_ir\s*=\s*(true|false)", text, re.MULTILINE)
    bh = re.search(r"""^\s*bytecode_hash\s*=\s*["'](\w+)["']""", text, re.MULTILINE)
    ev = re.search(r"""^\s*evm_version\s*=\s*["']([\w-]+)["']""", text, re.MULTILINE)
    rem = []
    p = subprocess.run(["forge", "remappings"], cwd=root,
                       capture_output=True, text=True, timeout=120)
    if p.returncode == 0:
        rem = [l.strip() for l in p.stdout.splitlines() if l.strip()]
    return {
        "solc": solc_from_tail,
        "optimizer": {"enabled": True, "runs": int(runs.group(1)) if runs else 200},
        "viaIR": bool(via and via.group(1) == "true"),
        "evmVersion": ev.group(1) if ev else "prague",
        "bytecodeHash": bh.group(1) if bh else "ipfs",
        "libraries": {},
        "remappings": rem,
        "sources": {},
        "target": {},
    }, (f"archived foundry.toml + `forge remappings` in {root}. "
        "⚠️ TWO OF THESE ARE NOT READABLE FROM THE DEPLOYED BYTES: the evm "
        "version is an assumption, and the remappings come from the forge "
        "installed NOW -- measured to differ from the original build's list, "
        "which moves the metadata hash and therefore the tail.")


def write_standard_json(root: str, sources: list, st: dict, out_path: str,
                        contract: str, entry: str) -> str:
    doc = {
        "language": "Solidity",
        "sources": {rel: {"content": open(os.path.join(root, rel),
                                          encoding="utf-8").read()}
                    for rel in sources},
        "settings": {
            "optimizer": st["optimizer"],
            "viaIR": st["viaIR"],
            "evmVersion": st["evmVersion"],
            "metadata": {"bytecodeHash": st["bytecodeHash"]},
            "libraries": st["libraries"],
            "remappings": st["remappings"],
            "outputSelection": {"*": {"*": ["evm.bytecode.object", "metadata"]}},
        },
    }
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1)
    return out_path


def solc_binary(version: str) -> str:
    """A solc of this exact version already on the machine, or None.

    Only looked for, never downloaded: fetching a compiler is a decision for
    whoever runs the build line, not for a script.
    """
    v = (version or "").split("+")[0]
    for cand in (os.path.expanduser(f"~/.local/share/svm/{v}/solc-{v}"),
                 os.path.expanduser(f"~/.svm/{v}/solc-{v}"),
                 os.path.expanduser(f"~/.solc-select/artifacts/solc-{v}/solc-{v}")):
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


# --------------------------------------------------------------------------
# the built bytes and THE ORACLE


def read_built(path: str) -> tuple:
    """The creation code out of whatever the build produced, plus its metadata
    if it carries any.

    Three shapes are accepted, because the three are what actually turn up:
    solc's standard-json OUTPUT, a forge artifact, and a plain hex dump. The
    last one is what makes the acceptance of this script possible without a
    compile: the oracle can be fed any bytes at all, including the recorded
    ones and the recorded ones with a byte moved.
    """
    with open(path, "rb") as fh:
        head = fh.read(1)
    if head == b"{":
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        # solc standard-json output
        if isinstance(doc.get("contracts"), dict):
            errs = [e for e in doc.get("errors") or []
                    if e.get("severity") == "error"]
            if errs:
                raise Unmeasurable(
                    "the build output carries compiler errors: " +
                    (errs[0].get("formattedMessage") or "")[:300])
            for _src, contracts in doc["contracts"].items():
                for _name, c in contracts.items():
                    obj = (((c.get("evm") or {}).get("bytecode") or {})
                           .get("object") or "")
                    if obj:
                        meta = c.get("metadata")
                        return obj.lower().removeprefix("0x"), (
                            json.loads(meta) if isinstance(meta, str) else None)
            raise Unmeasurable(f"{path} is solc output with no bytecode in it")
        # forge artifact
        obj = ((doc.get("bytecode") or {}).get("object") or "")
        if obj:
            meta = doc.get("metadata")
            if not isinstance(meta, dict) and isinstance(doc.get("rawMetadata"), str):
                meta = json.loads(doc["rawMetadata"])
            return obj.lower().removeprefix("0x"), meta
        raise Unmeasurable(f"{path} is JSON but holds no creation code")
    # a hex dump, with or without 0x and whitespace
    text = open(path, encoding="utf-8", errors="replace").read()
    hexed = re.sub(r"\s+", "", text).lower().removeprefix("0x")
    if not hexed or re.search(r"[^0-9a-f]", hexed) or len(hexed) % 2:
        raise Unmeasurable(f"{path} is neither JSON nor an even-length hex dump")
    return hexed, None


def oracle(built: str, recorded: str) -> dict:
    """Byte for byte, WHOLE. The constructor takes no arguments, so there is
    nothing to mask, and the tail is not stripped -- for two commits with the
    same code the tail is the ONLY thing that differs, so stripping it would
    make the oracle agree with the wrong source.
    """
    r = {
        "ok": built == recorded,
        "built_bytes": len(built) // 2,
        "recorded_bytes": len(recorded) // 2,
        "built_tail": tail_info(built),
        "recorded_tail": tail_info(recorded),
        "first_diff": None,
        "diff_count": 0,
        "all_in_tail": None,
    }
    if r["ok"]:
        return r
    n = min(len(built), len(recorded))
    offs = [i // 2 for i in range(0, n, 2) if built[i:i + 2] != recorded[i:i + 2]]
    r["diff_count"] = len(offs) + abs(len(built) - len(recorded)) // 2
    if offs:
        r["first_diff"] = offs[0]
    elif len(built) != len(recorded):
        r["first_diff"] = n // 2
    # Does every difference sit inside the metadata tail? That is the
    # interesting question, because the tail is where "same source, different
    # build environment" shows up, and the executable bytes being equal while
    # the tail differs is a completely different finding from a code change.
    rt = r["recorded_tail"]["declared"]
    bt = r["built_tail"]["declared"]
    if rt and bt and len(built) == len(recorded):
        start = (len(recorded) // 2) - max(rt, bt)
        r["all_in_tail"] = bool(offs) and min(offs) >= start
    return r


def cross_check_sources(meta, commit: str) -> list:
    """The rebuild's metadata names the keccak256 of every source it compiled.
    Matching those against the candidate commit's own files is the STRONG
    argument for the candidate -- it is about content, not about clocks, and it
    costs nothing.
    """
    out = []
    for rel, info in sorted(((meta or {}).get("sources") or {}).items()):
        want = (info.get("keccak256") or "").lower()
        try:
            got = keccak(git("show", f"{commit}:{rel}", binary=True))
        except Unmeasurable as exc:
            out.append((rel, want, None, str(exc)[:80]))
            continue
        out.append((rel, want, got, "MATCH" if got == want else "differs"))
    return out


# --------------------------------------------------------------------------
# the explorer: one door, and it is traced


class Explorer:
    """Every request to the explorer goes through here, and the trace line is
    written BEFORE the request leaves.

    That ordering is the whole point. "The publication was not attempted" is a
    claim about something NOT happening, and this project's rule for a zero is
    that the same instrument must show a non-zero where the thing certainly is.
    The trace file does: on an exact match it holds one line, on a mismatch it
    holds none, and both are read out of the same file by the same code path.
    The key is never written to it, nor is the body -- only the action and the
    body's size.
    """

    def __init__(self, url: str, key: str, trace: str = None, dry: bool = False):
        self.url, self.key, self.trace, self.dry = url, key, trace, dry
        self.sent = 0

    def _trace(self, action: str, nbytes: int, sent: bool):
        if not self.trace:
            return
        host = urllib.parse.urlparse(self.url).netloc
        with open(self.trace, "a", encoding="utf-8") as fh:
            fh.write("%s %s action=%s bodybytes=%d %s\n" % (
                time.strftime("%Y-%m-%dT%H:%M:%S"), host, action, nbytes,
                "SENT" if sent else "WITHHELD(dry-run)"))

    def post(self, params: dict) -> dict:
        # ⚠️ `chainid` RIDES IN THE URL, NOT ONLY IN THE BODY. The v2 endpoint
        # routes on it before it looks at a body, and a submission that carried
        # it in the body alone came back "Missing or unsupported chainid
        # parameter (required for v2 api)" -- measured on the owner's run of
        # 31 October 2026 after the oracle had already matched. `get()` below
        # had it in the URL all along, which is why the reading half worked and
        # the writing half did not; the publication gate next door puts it
        # there too. It stays in the body as well: the body is harmless and
        # the asymmetry was the whole defect.
        body = urllib.parse.urlencode(dict(params, apikey=self.key)).encode()
        self._trace(params.get("action", "?"), len(body), not self.dry)
        if self.dry:
            return {"status": "dry", "result": "not sent: --dry-send"}
        self.sent += 1
        url = self.url
        if params.get("chainid"):
            url = (f"{self.url}?"
                   + urllib.parse.urlencode({"chainid": params["chainid"]}))
        req = urllib.request.Request(url, data=body,
                                     headers={"user-agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
                return json.loads(r.read().decode())
        except (urllib.error.URLError, ValueError, OSError) as exc:
            raise Unmeasurable(f"{type(exc).__name__}: {exc}")

    def get(self, params: dict) -> dict:
        q = urllib.parse.urlencode(dict(params, apikey=self.key))
        self._trace(params.get("action", "?"), len(q), not self.dry)
        if self.dry:
            return {"status": "dry", "result": "not sent: --dry-send"}
        self.sent += 1
        req = urllib.request.Request(f"{self.url}?{q}",
                                     headers={"user-agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
                return json.loads(r.read().decode())
        except (urllib.error.URLError, ValueError, OSError) as exc:
            raise Unmeasurable(f"{type(exc).__name__}: {exc}")


def classify_submit(resp: dict) -> tuple:
    """(kind, detail) for the answer to a submission.

    'accepted' means the explorer took the source and gave a ticket. It does
    NOT mean published, and the caller must not print it as such.
    """
    status = str(resp.get("status"))
    result = str(resp.get("result") or resp.get("message") or "")
    low = result.lower()
    # The withheld request is answered FIRST, before anything that looks like
    # the explorer talking. Measured 31 October 2026: with this test below the
    # refusal branch, --dry-send printed "REFUSED. The explorer did not take
    # the source" -- a sentence about an explorer that was never asked. A
    # rehearsal that reports somebody else's verdict is worse than no
    # rehearsal.
    if status == "dry":
        return "dry", result
    if status == "1" and result:
        return "accepted", result
    if "rate limit" in low or "max rate" in low or "too many" in low:
        return "ratelimited", result
    if "already verified" in low:
        return "already", result
    return "refused", result or json.dumps(resp)[:200]


def classify_status(resp: dict) -> tuple:
    """(kind, detail) for the answer to a status poll."""
    result = str(resp.get("result") or resp.get("message") or "")
    low = result.lower()
    if "pending" in low or "in queue" in low:
        return "pending", result
    if "already verified" in low:
        return "already", result
    if str(resp.get("status")) == "1" and ("pass" in low or "verified" in low):
        return "verified", result
    if "rate limit" in low or "max rate" in low:
        return "ratelimited", result
    if "fail" in low or "unable to verify" in low:
        return "failed", result
    return "unknown", result or json.dumps(resp)[:200]


# --------------------------------------------------------------------------
# the verdict


def watchdog_verdict() -> tuple:
    """(exit code, tail of output). The gate next door, run again.

    Not `forge verify`'s exit status: that one asks two verifiers and prints
    the tail of one, and it is 0 almost always. The watchdog asks the explorer
    about every body a live clone executes, and its exit code is the answer.
    """
    p = subprocess.run(["./script/check-clone-implementations.sh"],
                       capture_output=True, text=True, timeout=900)
    return p.returncode, ((p.stdout or "") + (p.stderr or ""))[-1500:]


# --------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="publish-archived-implementation.sh",
        description="Rebuild and publish an implementation whose source has "
                    "left the tree, behind a byte-for-byte oracle.")
    ap.add_argument("address", help="the implementation to publish")
    ap.add_argument("--work-dir", help="where to extract the archived commit")
    ap.add_argument("--settings-from", metavar="PATH",
                    help="a recorded build (forge artifact / metadata / solc "
                         "output) to lift the compiler settings from")
    ap.add_argument("--built", metavar="PATH",
                    help="the ALREADY BUILT creation code: solc output JSON, "
                         "forge artifact, or a hex dump. Without it the run "
                         "stops after preparing the build line.")
    ap.add_argument("--submit", action="store_true",
                    help="send the source to the explorer -- reached only on "
                         "an exact match")
    ap.add_argument("--dry-send", action="store_true",
                    help="walk the publication path but withhold the request")
    ap.add_argument("--trace", metavar="FILE",
                    help="append one line per explorer request, written "
                         "before the request leaves")
    ap.add_argument("--explorer-url", default=EXPLORER,
                    help="⚠️ test seam: where the explorer lives")
    ap.add_argument("--rpc", default=os.environ.get("RPC_URL") or DEFAULT_RPC)
    ap.add_argument("--offline", action="store_true",
                    help="skip the chain read (it is a cross-check, not the oracle)")
    ap.add_argument("--no-verdict", action="store_true",
                    help="do not run the watchdog after publishing")
    a = ap.parse_args()

    addr = a.address.lower()
    if not re.fullmatch(r"0x[0-9a-f]{40}", addr):
        print(f"{addr} is not an address", file=sys.stderr)
        return DAMAGED

    print("=" * 74)
    print(f"ARCHIVED IMPLEMENTATION {addr}")
    print("=" * 74)

    # ---- 1. our own record of the deployment, found by address
    try:
        (snap_path, doc, tx), all_paths = find_snapshot(addr)
        recorded = code_of(tx)
        at, unit = deploy_moment(doc)
    except Damaged as exc:
        print(f"\nDAMAGED: {exc}", file=sys.stderr)
        return DAMAGED
    rt = tail_info(recorded)
    contract = tx.get("contractName") or "?"
    print(f"\n[1] OUR OWN BYTE RECORD, found by searching broadcast/ for the address")
    print(f"    {snap_path}")
    if len(all_paths) > 1:
        print(f"    (the same run also in: {', '.join(all_paths[1:])})")
    print(f"    contract .............. {contract}")
    print(f"    creation code ......... {len(recorded) // 2} bytes")
    print(f"    metadata tail ......... {rt['declared']} bytes, solc {rt['solc']}, "
          f"{'WITH' if rt['has_ipfs'] else 'without'} a source hash")
    print(f"    deployed .............. {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(at))}"
          f"  /  {time.strftime('%Y-%m-%d %H:%M:%S %z', time.localtime(at))}"
          f"   [timestamp unit: {unit}]")
    label = doc.get("commit")
    print(f"    commit label by forge . {label!r} -- "
          + ("present in this repository" if label and object_exists(str(label))
             else "⚠️ NOT AN OBJECT IN THIS REPOSITORY. The label is unusable; "
                  "the bytes are the judge."))

    # ---- 2. the chain, as a cross-check on the record (never as the oracle)
    if a.offline:
        print("\n[2] chain cross-check SKIPPED (--offline). Not a pass, just not asked.")
    else:
        try:
            live = chain_code(addr, a.rpc)
            tails = recorded.endswith(live)
            print(f"\n[2] CHAIN CROSS-CHECK: body on chain {len(live) // 2} bytes; "
                  f"the record's last {len(live) // 2} bytes are that body: {tails}")
            if not tails:
                say("⚠️ the record does not end with the live body. Either the "
                    "record is of a different deployment or the body was "
                    "redeployed. STOPPING.", "    ", sys.stderr)
                return DAMAGED
            print(f"    first {(len(recorded) - len(live)) // 2} bytes of the record "
                  f"are the constructor")
        except Unmeasurable as exc:
            print(f"\n[2] COULD NOT READ THE CHAIN: {exc}")
            say("This is a cross-check, not the oracle; continuing, and "
                "saying so rather than calling it a pass.", "    ")

    # ---- 3. the candidate commit, with its argument printed
    try:
        src = source_path_of(contract)
        cand = candidate_commit(src, at)
    except (Damaged, Unmeasurable) as exc:
        print(f"\nCANNOT DERIVE A CANDIDATE: {exc}", file=sys.stderr)
        return DAMAGED
    print(f"\n[3] CANDIDATE COMMIT, and the argument for it")
    print(f"    last change to {src} at or before the deployment:")
    print(f"      {cand['commit'][:12]}  {cand['commit_date']}")
    print(f"    HEAD at the deployment moment:")
    print(f"      {cand['head_at_deploy'][:12]}  {cand['head_date']}")
    if cand["head_at_deploy"] != cand["commit"]:
        paths = cand["changed_between"]
        risky = [p for p in paths
                 if p.startswith(("src/", "lib/")) or p in ("foundry.toml",
                                                            "remappings.txt")]
        print(f"    between them {len(paths)} files changed, of which "
              f"{len(risky)} could change this contract's bytes: "
              f"{risky or 'none'}")
        print(f"    positive control for that zero -- the same command does "
              f"report changes elsewhere, e.g.")
        for p in paths[:2]:
            print(f"      {p}")
    say("⚠️ This is an ORDER argument, not an identity: it says no later source "
        "could have been deployed, not that this one was. The identity comes "
        "from the oracle below, and from the source hashes in [6].", "    ")

    # ---- 4. the isolated tree + the compiler input + the owner's one line
    # Not under /tmp by default: a reboot sweeps that directory, and on
    # 30 October 2026 it swept a prepared task and three measurement logs with
    # it. The compiler input here is meant to be handed to somebody else and
    # run later, so it lives where "later" still exists.
    work = a.work_dir or os.path.expanduser(
        f"~/hexseal-archive/{cand['commit'][:12]}")
    print(f"\n[4] ISOLATED TREE (the working tree is not touched)")
    if os.path.isdir(work) and os.listdir(work):
        print(f"    reusing {work} (already populated)")
    else:
        try:
            materialise(cand["commit"], work)
        except (Damaged, Unmeasurable) as exc:
            print(f"\nDAMAGED: {exc}", file=sys.stderr)
            return DAMAGED
        print(f"    extracted {cand['commit'][:12]} into {work} with `git archive`")

    try:
        if a.settings_from:
            st, prov = settings_from(a.settings_from)
        else:
            st, prov = settings_fallback(work, rt["solc"])
    except (Damaged, Unmeasurable) as exc:
        print(f"\nDAMAGED: {exc}", file=sys.stderr)
        return DAMAGED
    if not st.get("solc"):
        st["solc"] = rt["solc"]
    print(f"    compiler settings from:")
    say(prov, "      ")
    print(f"      solc {st['solc']}   optimizer {st['optimizer']}")
    print(f"      viaIR {st['viaIR']}   evmVersion {st['evmVersion']}   "
          f"bytecodeHash {st['bytecodeHash']}")
    print(f"      remappings ({len(st['remappings'])}):")
    for r in st["remappings"]:
        print(f"        {r}")
    if rt["solc"] and st["solc"] and not str(st["solc"]).startswith(rt["solc"]):
        say(f"⚠️ the deployed tail says solc {rt['solc']} and these settings say "
            f"{st['solc']}. The oracle will refuse; fix the settings.", "    ")

    try:
        files = closure(work, src, st["remappings"])
    except Damaged as exc:
        print(f"\nDAMAGED: {exc}", file=sys.stderr)
        return DAMAGED
    inp = os.path.join(work, "standard-json-input.json")
    write_standard_json(work, files, st, inp, contract, src)
    print(f"    compilation closure: {len(files)} file(s): {files}")
    print(f"    compiler input written: {inp}")

    # The settings are copied into the work directory as well, so that the
    # second invocation -- the one that runs the oracle -- does not have to
    # reach the place they were lifted from. That place can be a removable
    # disk, and a handover line that stops working when a disk is unplugged is
    # not a handover line.
    side = os.path.join(work, "recorded-settings.json")
    with open(side, "w", encoding="utf-8") as fh:
        json.dump({
            "_provenance": prov,
            "compiler": {"version": st["solc"]},
            "settings": {
                "compilationTarget": {src: contract},
                "evmVersion": st["evmVersion"],
                "libraries": st["libraries"],
                "metadata": {"bytecodeHash": st["bytecodeHash"]},
                "optimizer": st["optimizer"],
                "remappings": st["remappings"],
                "viaIR": st["viaIR"],
            },
            "sources": st["sources"],
        }, fh, indent=1)
    print(f"    settings copied here too: {side}")

    sol = solc_binary(st["solc"])
    out_json = os.path.join(work, "solc-output.json")
    v = str(st["solc"]).split("+")[0]
    if sol:
        compile_cmd = f"'{sol}' --standard-json '{inp}' > '{out_json}'"
    else:
        compile_cmd = (f"solc-select install {v} && solc-select use {v} && "
                       f"solc --standard-json '{inp}' > '{out_json}'")
    here = os.path.abspath(".")
    # The line is handed over as a FILE, not as text to copy: a long command
    # gets broken by the line wrap on its way through a chat window, measured
    # three times on 30 October 2026. Two files, because the cautious path and
    # the one-press path are different jobs.
    build_sh = os.path.join(work, "build.sh")
    go_sh = os.path.join(work, "go.sh")
    with open(build_sh, "w", encoding="utf-8") as fh:
        fh.write("#!/usr/bin/env bash\n# Compile the archived source, nothing "
                 "else. Writes solc-output.json next to this file.\nset -eu\n"
                 f"{compile_cmd}\n"
                 f"echo \"solc output: $(wc -c < '{out_json}') bytes\"\n")
    with open(go_sh, "w", encoding="utf-8") as fh:
        fh.write("#!/usr/bin/env bash\n# Compile, then let the ORACLE decide "
                 "whether anything is published, then take the verdict from "
                 "the watchdog.\nset -eu\n"
                 f"bash '{build_sh}'\n"
                 f"cd '{here}'\n"
                 f"./script/publish-archived-implementation.sh {addr} \\\n"
                 f"  --work-dir '{work}' --settings-from '{side}' \\\n"
                 f"  --built '{out_json}' --submit\n")
    os.chmod(build_sh, 0o755)
    os.chmod(go_sh, 0o755)
    # ⚠️ THE HANDOVER FILE IS THE DELIVERABLE, SO IT IS PARSED BEFORE IT IS
    # OFFERED. Measured on 31 October 2026: the first build.sh this wrote had
    # an unbalanced quote and died with "unexpected EOF" -- and `bash -n` on
    # go.sh stayed green, because go.sh only CALLS build.sh and a caller does
    # not parse its callee. So both are checked, each on its own.
    for sh in (build_sh, go_sh):
        chk = subprocess.run(["bash", "-n", sh], capture_output=True, text=True)
        if chk.returncode != 0:
            print(f"\nDAMAGED: the handover script {sh} does not parse: "
                  f"{(chk.stderr or '').strip()[:200]}", file=sys.stderr)
            return DAMAGED
    if a.built:
        # The build has already happened; repeating the handover block here
        # only pushes the verdict further down the screen. And the compile
        # command is the one line in this output that must NOT be wrapped --
        # it carries paths and has to survive a copy -- so the place it is
        # printed is the run where somebody is looking for it.
        print(f"\n    handover scripts (the build is already done): {go_sh}")
    else:
        say("THE BUILD STEP IS NOT RUN FROM HERE: a full via_ir build of this "
            "tree peaks near 12 GB and outlives a tool call.", "    ")
        print(f"    ONE LINE, for the owner "
              f"(compile -> oracle -> publish -> verdict):")
        print(f"\n      bash {go_sh}\n")
        print(f"    compile only, to look before publishing:")
        print(f"      bash {build_sh}")
        print(f"    what the compile actually runs (one line, on purpose):")
        print(f"      {compile_cmd}")

    if not a.built:
        print("\n[stopping here: no --built given. Nothing was published.]")
        return OK

    # ---- 5. THE ORACLE
    try:
        built, bmeta = read_built(a.built)
    except Unmeasurable as exc:
        print(f"\nCOULD NOT READ THE BUILD: {exc}", file=sys.stderr)
        return UNMEASURABLE
    o = oracle(built, recorded)
    print(f"\n[5] THE ORACLE: built bytes against our recorded bytes, whole")
    print(f"    built    {o['built_bytes']} bytes   (from {a.built})")
    print(f"    recorded {o['recorded_bytes']} bytes   (from {snap_path})")
    if o["ok"]:
        print(f"    ✔ IDENTICAL, all {o['recorded_bytes']} bytes, tail included.")
    else:
        print(f"    ✘ NOT IDENTICAL.")
        if o["built_bytes"] != o["recorded_bytes"]:
            print(f"      length differs by "
                  f"{o['built_bytes'] - o['recorded_bytes']:+d} bytes")
        print(f"      first differing byte at offset {o['first_diff']} "
              f"(0-based, of {o['recorded_bytes']})")
        print(f"      differing bytes: {o['diff_count']}")
        bt, rtl = o["built_tail"], o["recorded_tail"]
        print(f"      metadata tail declared: built {bt['declared']}, "
              f"recorded {rtl['declared']}")
        if bt["declared"] != rtl["declared"]:
            say("⚠️ THE TWO SIDES DECLARE DIFFERENT TAIL LENGTHS. The last two "
                "bytes are the CBOR length; a difference there is a different "
                "build environment, a truncated dump, or bytes that are not a "
                "metadata tail at all -- not a different source.")
        print(f"      built    solc {bt['solc']}  tail "
              f"{clip_hex(bt['tail'])}")
        print(f"      recorded solc {rtl['solc']}  tail "
              f"{clip_hex(rtl['tail'])}")
        if o["all_in_tail"]:
            say("⚠️ EVERY DIFFERENCE IS INSIDE THE METADATA TAIL: the "
                "executable bytes agree and the metadata does not. That is the "
                "same source compiled under a different environment "
                "(remappings list, source path, compiler build), not a "
                "different source.")
        print(f"\n    NOTHING WAS PUBLISHED. The explorer was not asked: "
              f"{0} requests.")
        return MISMATCH

    # ---- 6. the second, independent argument for the candidate: source hashes
    if bmeta:
        rows = cross_check_sources(bmeta, cand["commit"])
        print(f"\n[6] SOURCE HASHES in the rebuild's own metadata, against "
              f"{cand['commit'][:12]}'s tree")
        for rel, want, got, how in rows:
            print(f"    {how:8}  {rel}")
            print(f"              metadata {want}")
            print(f"              commit   {got}")
        if any(r[3] != "MATCH" for r in rows):
            say("⚠️ a hash disagrees while the bytes matched. Read this as a "
                "warning about the candidate label, not about the bytes.", "    ")
    else:
        print(f"\n[6] the build carries no metadata, so the source-hash "
              f"cross-check was NOT performed. Not a pass, just not asked.")

    # ---- 7. publication, reached only because the oracle said identical
    if not a.submit:
        print("\n[7] --submit not given, so the explorer was not asked. "
              "The oracle matched; publication is one flag away.")
        return OK

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        from check_sources_published import api_key
    except ImportError:
        api_key = lambda: (os.environ.get("ETHERSCAN_API_KEY"), "environment")
    key, which = api_key()
    if not key:
        print("\n[7] NO EXPLORER KEY. Nothing was asked, and a missing key is "
              "not a pass.", file=sys.stderr)
        return UNMEASURABLE
    print(f"\n[7] PUBLISHING. Key from {which}; its value is never printed.")
    if a.explorer_url != EXPLORER:
        print(f"    ⚠️ NOT THE REAL EXPLORER: {a.explorer_url}")
    ex = Explorer(a.explorer_url, key, a.trace, a.dry_send)
    payload = {
        "chainid": CHAIN_ID,
        "module": "contract",
        "action": "verifysourcecode",
        "codeformat": "solidity-standard-json-input",
        "sourceCode": open(inp, encoding="utf-8").read(),
        "contractaddress": addr,
        "contractname": f"{src}:{contract}",
        "compilerversion": "v" + str(st["solc"]),
    }
    try:
        resp = ex.post(payload)
    except Unmeasurable as exc:
        print(f"    COULD NOT REACH THE EXPLORER: {exc}", file=sys.stderr)
        print(f"    requests sent: {ex.sent}. The chain is untouched either way.")
        return UNREACHABLE
    kind, detail = classify_submit(resp)
    print(f"    submission: {kind} -- {detail[:200]}")
    if kind == "dry":
        say("WITHHELD BY REQUEST (--dry-send). The publication path ran and "
            "the request did not leave, so NOTHING was published and nothing "
            "was asked. Not a pass: there is no verdict to have.", "    ")
        return UNMEASURABLE
    if kind == "ratelimited":
        print("    RATE-LIMITED. The source was not taken. Retry later; one line:")
        print(f"      bash {go_sh}")
        return UNREACHABLE
    if kind == "refused":
        print("    REFUSED. The explorer did not take the source.")
        return REFUSED
    guid = detail
    final = None
    for i in range(POLL_TRIES):
        time.sleep(POLL_PAUSE)
        try:
            st_resp = ex.get({"chainid": CHAIN_ID, "module": "contract",
                              "action": "checkverifystatus", "guid": guid})
        except Unmeasurable as exc:
            print(f"    could not poll the ticket: {exc}")
            break
        k, d = classify_status(st_resp)
        print(f"    poll {i + 1}: {k} -- {d[:160]}")
        if k in ("verified", "already", "failed", "refused"):
            final = (k, d)
            break
        final = (k, d)
    if not final or final[0] in ("pending", "unknown", "ratelimited"):
        say("⚠️ ACCEPTED AND STILL IN THE QUEUE. This is NOT 'published'. The "
            "source is with the explorer, the verdict does not exist yet.", "    ")
        print(f"    re-run the verdict later, one line:")
        print("      ./script/check-clone-implementations.sh")
        return PENDING
    if final[0] == "failed":
        print("    THE EXPLORER COULD NOT VERIFY THE SOURCE. Not published.")
        return REFUSED

    # ---- 8. the verdict, from the watchdog
    if a.no_verdict:
        print("\n[8] verdict SKIPPED (--no-verdict). The explorer said "
              f"{final[0]!r}; that is the builder talking, not the watchdog.")
        return OK
    print("\n[8] THE VERDICT, from the watchdog rather than from the submission")
    code, tail = watchdog_verdict()
    print(tail)
    print(f"    check-clone-implementations.sh exited {code}")
    if code == 0:
        print("    ✔ PUBLISHED: every body a live clone executes has a source.")
        return OK
    if code == 1:
        say("✘ THE WATCHDOG STILL SAYS NO. The explorer answered "
            f"{final[0]!r} and the reading disagrees. Do not report this as "
            "published.", "    ")
        return CONTRADICTED
    print("    the watchdog could not measure. That is not a pass.")
    return UNMEASURABLE


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(UNMEASURABLE)
