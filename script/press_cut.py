#!/usr/bin/env python3
"""One press: the diamond cut, the publication of every contract it created,
and a verdict that comes from the watchdogs rather than from the submission.

Run it through ./script/press-cut.sh (that wrapper checks the working
directory and the tools).

---------------------------------------------------------------------------
WHY THIS EXISTS -- COUNTED, NOT FELT

Publishing the sources was never part of pressing a cut. It was a separate
action, done afterwards, by whoever remembered. Over three weeks it was
forgotten four times, and not one of the four was noticed on the day of the
cut (the open-items log, item 109, holds the table). Forgetting was not
carelessness; it was the shape of the work. A step that is not inside the
press is a step that depends on memory, and memory is the part of this project
that has never been measured.

The owner's decision 250 says publication must travel inside the same action
as the cut, and that the verdict must come from a watchdog rather than from
whatever the submission answers. This script is line 1 of that decision.

---------------------------------------------------------------------------
THE VERDICT IS THE WATCHDOGS', AND THERE ARE TWO OF THEM

`forge script --verify` and `forge verify-contract` ask two verifiers, print
the tail of one, and exit 0 almost always. So nothing here concludes
"published" from an answer to a submission. Publication is a REQUEST; the
verdict is a separate READING, taken from two gates that ask the explorer what
it holds:

    check-sources-published.sh      every contract of the LIVE protocol
    check-clone-implementations.sh  every body a LIVE CLONE executes

Both must exit 0. One of them green is not a verdict: they answer about
different rosters -- the first about what the next deal will run, the second
about what existing deals already run for ever, because an EIP-1167 clone
carries its implementation inside its own body and never changes it.

⚠️ AND THE SUBMISSION'S ANSWER CAN ONLY LOWER THE VERDICT, NEVER RAISE IT.
Both watchdogs green is NOT by itself "this cut is published", because their
two rosters are the live protocol and the bodies live clones run -- and a cut
can create something on NEITHER roster. An init helper (ArbiterProvenanceInit,
TreasuryLinkInit) is deployed, called once and never mounted: no roster names
it, so both gates stay green whether its source is up or not. So a refusal, a
queue or an unreachable explorer for ANY created contract keeps the run red
even with both gates green. The watchdogs hold the veto; the submission holds
a second, independent veto; neither can grant a pass on its own.

They are run one after the other, never together: two gates in parallel fight
over the same explorer rate limit, and a red that is really a rate limit is
the worst kind -- it looks exactly like the thing the gate is for.

---------------------------------------------------------------------------
⚠️ THE CUT IS NOT PRESSED FROM A TOOL CALL. EVER.

Writing to the chain is the owner's keypress. A run without --press stops
after the checks and prints ONE READY LINE for him. Everything after the cut
-- reading the record, publishing, taking the verdict -- is also reachable on
its own with --after-cut against a record that already exists, of which this
repository holds over a hundred. That is deliberate: the whole second half of
this script has to be provable without a single byte going to the chain, and
that is how it was accepted.

---------------------------------------------------------------------------
⚠️ WHAT RUNS AND WHAT IS PRINTED ARE TWO DIFFERENT STRINGS

The credential flags are passed through to forge after a `--`, and the shell
expands `"$PRIVATE_KEY"` BEFORE this script is started: what arrives in argv is
the key itself. Printing the command it is about to run would therefore put a
wallet key on the screen and, because this output is normally piped into a run
log, on the disk -- and a key that has reached a log cannot be taken out of it.

So the command is built once with real values and EXECUTED, and what gets
printed is a different string: this script's own two tokens and the NUMBER of
arguments it was handed. Not one pass-through argument is printed, in any form.

⚠️ The design before this one classified tokens -- "looks like a flag" was
printed, the rest replaced -- and leaked on the first form it had not thought
of: `-k<key>`, a short flag with its value glued on, starts with a dash, holds
no `=`, and went out whole. The lesson is not the missed form. It is that a
classifier here is a GUESS, and a guess about a secret errs towards disclosing
it. The line is for seeing WHICH cut runs, not for reconstructing the command
-- whoever runs it typed it -- so nothing in it comes from the arguments at
all, and then nothing in it can be wrong.

---------------------------------------------------------------------------
WHERE THE ADDRESSES COME FROM, AND WHY THEY ARE CROSS-CHECKED

From the broadcast record, by TRANSACTION TYPE: every transaction whose
`transactionType` is CREATE. Not from a document, not from an argument, not
from a label -- a list typed by hand is a list that publishes last week's
facet to this week's address.

But a record can also be WRONG, and then publishing "every CREATE in it" is
publishing less than the cut made, silently. So the set of CREATE addresses is
compared with two other sides of the same file:

  * THE RECEIPTS. `receipts[].contractAddress` is filled from the chain's own
    receipt, not from the script's labels. Compared as a SET, never by
    position: forge keeps transactions and receipts as two lists paired by
    position, the mined order is not the broadcast order, and that mismatch
    has already sent four contracts' sources to the wrong addresses here
    (29 September 2026). A set comparison cannot be fooled by the order; it
    only asks "the same addresses, both sides".

  * THE CUT'S OWN CALLDATA. A facet created to be mounted appears as 20 bytes
    inside the diamondCut call this same script sent. A record that has lost a
    CREATE still carries that address there.

Either side disagreeing stops the run before anything is published, and says
how many it would have published out of how many exist. A record that has lost
a transaction must not end as a quiet publication of the rest.

What this cannot see, said out loud: a contract deployed INSIDE another
contract's call (forge files those under `additionalContracts`, not as a
CREATE). Measured across all 106 chain-84532 records in this repository on
31 October 2026: zero such entries, with the same reader finding CREATEs in 99
of them -- so the hole is real and currently empty. If one ever appears, this
script says so and refuses rather than publishing around it.

---------------------------------------------------------------------------
WHAT IS SUBMITTED

For each created contract: a standard-json input built from the tree, with the
compiler settings LIFTED FROM THE ARTIFACT THAT PRODUCED THE DEPLOYED BYTES
(out/<dir>/<Name>.json), not from a literal here and not from foundry.toml as
it stands today. The source list is that artifact metadata's own, which is
exactly the set the deployed metadata hash covers.

Two guards around that, because an artifact is a file on disk and files go
stale:

  * the tree must be clean, and the record's commit must be this HEAD. A cut
    published from a tree that has moved on submits sources that were never
    deployed. The explorer would mostly catch that and refuse; "mostly" is not
    a guard.
  * before anything is submitted, ./script/verify-cut-addresses.sh must agree
    that every name in the record belongs to the address it sits next to --
    the gate that exists because that was once wrong for five addresses out of
    nine. Skippable only with a loud flag, and the skip is printed as a
    weakening, never as a pass.

---------------------------------------------------------------------------
EXIT CODES -- AND NONE OF THEM IS ROUNDED TOWARDS SUCCESS

    0   prepared (no --press), or: published AND both watchdogs exit 0
    1   REFUSED TO START. Dirty tree, no such script, no record. Nothing ran
        and the chain was not touched.
    2   DAMAGED. The record contradicts itself or the tree: a CREATE is
        missing, an address is in the receipts with no transaction, the commit
        is not this HEAD, the address oracle said a name sits on the wrong
        body -- or the press ran, succeeded, and wrote NO record, in which case
        the record on disk is an older cut's and this press has nothing of its
        own to publish. NOTHING was published.
    3   COULD NOT MEASURE. No explorer key, no artifact for a created
        contract, a gate could not ask, the requests were withheld. NOT a pass.
    5   the explorer REFUSED a source, or could not verify it.
    6   the explorer was UNREACHABLE or rate-limited us.
    7   ACCEPTED AND STILL QUEUED -- deferred, not published. Deliberately not
        0, and deliberately not the same word as a refusal.
    8   the explorer said verified and a WATCHDOG DISAGREES.
    9   ⚠️ THE CUT LANDED IN THIS RUN AND THE PUBLICATION DID NOT FINISH. The
        chain has changed and cannot be un-pressed; this is the one code that
        means a human has to come back. It carries its own loud paragraph and
        ONE READY LINE that finishes the job without cutting again.

Exit 9 REPLACES the specific code when the cut was pressed in this same run,
because by then the reason matters less than the fact that the chain moved and
the sources are not up.

---------------------------------------------------------------------------
THE ONE SUCCESS SENTENCE

Exactly one token in this file says the work is done, it is printed on one
road only, and it is this: "press-cut: DONE". Every other ending prints
"press-cut: NOT DONE -- <why>". That is not decoration: a queued submission,
an unreachable explorer and a disagreeing watchdog all read like success if
you skim, and one greppable token makes "did it finish?" answerable without
reading prose.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# ⚠️ IMPORTED, NOT COPIED. The explorer door (with `chainid` in the URL as well
# as in the body -- the asymmetry that made every publication impossible until
# 31 October 2026), the refusal taxonomy, the settings lift and the
# standard-json writer all live next door and were measured there. A second
# copy of any of them is a second thing to fix.
from publish_archived_implementation import (  # noqa: E402
    CHAIN_ID,
    DEFAULT_RPC,
    EXPLORER,
    POLL_PAUSE,
    POLL_TRIES,
    Damaged,
    Unmeasurable,
    Explorer,
    classify_status,
    classify_submit,
    say,
    settings_from,
    write_standard_json,
)

OK = 0
REFUSED_TO_START = 1
DAMAGED = 2
UNMEASURABLE = 3
REFUSED = 5
UNREACHABLE = 6
QUEUED = 7
CONTRADICTED = 8
CUT_LANDED_UNPUBLISHED = 9

DONE = "press-cut: DONE"
NOT_DONE = "press-cut: NOT DONE"

WATCHDOGS = ("check-sources-published.sh", "check-clone-implementations.sh")


def run(args, timeout=900, cwd=None):
    return subprocess.run(args, capture_output=True, text=True,
                          timeout=timeout, cwd=cwd)


# ── THE COMMAND THAT RUNS AND THE COMMAND THAT IS PRINTED ARE TWO THINGS ─────
#
# ⚠️ THE SHELL EXPANDS `"$PRIVATE_KEY"` BEFORE argv EVER REACHES THIS FILE.
# What arrives is the key ITSELF, and printing the command therefore prints a
# wallet key -- to the terminal and, because this output is normally piped into
# a run log, to disk, where it cannot be taken back out again. The house rule is
# flat: an environment VALUE is never printed, only a derived fact.
#
# SO NO PASS-THROUGH ARGUMENT IS PRINTED AT ALL. Only their number is.
#
# That is the second of two designs, and the first one is worth writing down
# because it looked safe and was not. It classified each token: one that looks
# like a flag is printed, anything else is a value and is replaced. "Looks like
# a flag" meant "starts with a dash" -- and a short flag with its value glued
# on, `-k<key>`, starts with a dash, contains no `=`, and travelled whole. The
# defect is not the missed form; it is that the decision was a GUESS, and a
# guess here errs towards disclosure. An allowlist of safe flag NAMES, matched
# whole, would be correct -- a name we do not know is then redacted rather than
# printed, so the list lags harmlessly. But once every value and every unknown
# token is redacted, what is left to print is `--broadcast` and a row of
# <redacted>, which carries exactly as much as a count does.
#
# The line exists so a reader can see WHICH cut is about to run, not so the
# command can be reconstructed from the screen: whoever runs it typed it. So it
# prints the script, the one flag this script adds itself, and how many
# arguments it was handed. Nothing in it can be wrong about a secret, because
# nothing in it comes from the arguments.


def cut_command(sol: str, forge_args) -> list:
    """The command that is actually EXECUTED, with real values. Never printed."""
    return ["forge", "script", sol, "--broadcast"] + list(forge_args)


def printable_command(sol: str, forge_args) -> str:
    """One line, safe to print and safe to land in a log.

    Built from this script's own two tokens and a COUNT. No argument the caller
    passed is in it, in any form, whatever it looks like.
    """
    n = len(forge_args)
    tail = (f"  + {n} argument(s) for forge, NOT printed"
            if n else "   (no further arguments were passed)")
    return f"forge script {sol} --broadcast{tail}"


def fail(text):
    """A refusal on stderr, with stdout FLUSHED FIRST.

    ⚠️ Measured 31 October 2026 in this very pipeline: `python3 -u` does NOT
    fix the ordering. Through a pipe into `tee`, a line written to stderr
    still arrives ahead of lines written to stdout before it -- probed three
    ways (with -u, without -u, via -c) and stderr came first every time. So
    the order is held here explicitly instead of being delegated to a flag
    that was believed to do it. A refusal printed above the step it refused is
    how a reader ends up blaming the wrong step.
    """
    sys.stdout.flush()
    print(text, file=sys.stderr)
    sys.stderr.flush()


def say_err(text, indent="    "):
    """`say`, on stderr, with stdout flushed first. Same reason as fail()."""
    sys.stdout.flush()
    say(text, indent, sys.stderr)
    sys.stderr.flush()


# --------------------------------------------------------------------------
# the tree


def tree_state():
    """(tracked changes, untracked paths). Two lists, because they are two
    different risks, and one refusal that mixes them is a refusal the reader
    argues with instead of acting on."""
    p = run(["git", "status", "--porcelain=v1", "--untracked-files=normal"], 60)
    if p.returncode != 0:
        raise Unmeasurable("git status failed: " + (p.stderr or "").strip()[:200])
    tracked, untracked = [], []
    for line in (p.stdout or "").splitlines():
        if not line.strip():
            continue
        code, path = line[:2], line[3:]
        (untracked if code == "??" else tracked).append((code, path))
    return tracked, untracked


def head_commit():
    p = run(["git", "rev-parse", "HEAD"], 60)
    return (p.stdout or "").strip() if p.returncode == 0 else None


def object_exists(rev: str) -> bool:
    return run(["git", "cat-file", "-t", rev], 60).returncode == 0


# --------------------------------------------------------------------------
# the record


def record_path(name: str) -> str:
    """broadcast/<Script>.s.sol/<chain>/run-latest.json for this script."""
    return os.path.join("broadcast", name + ".s.sol", CHAIN_ID,
                        "run-latest.json")


def read_record(path: str) -> dict:
    if not os.path.isfile(path):
        raise Damaged(f"no broadcast record at {path}")
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        raise Damaged(f"{path} is not readable JSON: {exc}")


def creates(doc: dict) -> list:
    """Every contract the record says it CREATED, found by transaction type."""
    out = []
    for i, tx in enumerate(doc.get("transactions") or []):
        if (tx.get("transactionType") or "").upper() != "CREATE":
            continue
        addr = (tx.get("contractAddress") or "").lower()
        if not re.fullmatch(r"0x[0-9a-f]{40}", addr):
            raise Damaged(f"transaction {i} is a CREATE with no usable "
                          f"contractAddress ({addr!r})")
        out.append({"i": i, "address": addr,
                    "name": tx.get("contractName") or ""})
    return out


def cross_check(doc: dict, made: list) -> tuple:
    """(findings, counts). Compared as SETS on purpose -- see the header."""
    findings = []
    tx_addrs = {c["address"] for c in made}

    rc_addrs = {(r.get("contractAddress") or "").lower()
                for r in (doc.get("receipts") or [])
                if r.get("contractAddress")}
    for a in sorted(rc_addrs - tx_addrs):
        findings.append(
            f"{a} has a RECEIPT of its own creation and NO CREATE transaction "
            f"in the same record. The record has lost a transaction: "
            f"publishing the remaining {len(tx_addrs)} would publish less than "
            f"the cut made.")
    for a in sorted(tx_addrs - rc_addrs):
        findings.append(
            f"{a} is a CREATE transaction with no creation receipt. Either it "
            f"never landed, or this record is of a run that was interrupted.")

    # The cut's own calldata: a facet made to be mounted is named inside it.
    blob = "".join(((t.get("transaction") or {}).get("input") or "").lower()
                   for t in (doc.get("transactions") or [])
                   if (t.get("transactionType") or "").upper() == "CALL")
    mounted = {a for a in (rc_addrs | tx_addrs) if a[2:] in blob}
    for a in sorted(mounted - tx_addrs):
        findings.append(
            f"{a} is an argument of the cut this record sent and is NOT among "
            f"its CREATE transactions.")

    extra = sum(len(t.get("additionalContracts") or [])
                for t in (doc.get("transactions") or []))
    if extra:
        findings.append(
            f"{extra} contract(s) were created INSIDE a call "
            f"(`additionalContracts`). This script publishes CREATE "
            f"transactions and would skip them. Publish those by hand and say "
            f"so, or teach this script about them -- do not let the run pass.")

    return findings, {"transactions": len(tx_addrs), "receipts": len(rc_addrs),
                      "named_in_cut": len(mounted), "inside_calls": extra,
                      "cut_calldata_bytes": len(blob) // 2}


# --------------------------------------------------------------------------
# the artifact and the compiler input


def artifact_for(name: str) -> str:
    """out/<dir>/<Name>.json, and only if exactly one answers.

    Two artifacts of the same name mean two contracts of that name in the
    tree, and then picking one is a guess about which was deployed.
    """
    hits = []
    if os.path.isdir("out"):
        for d in sorted(os.listdir("out")):
            cand = os.path.join("out", d, name + ".json")
            if os.path.isfile(cand):
                hits.append(cand)
    if not hits:
        raise Unmeasurable(
            f"no artifact for {name} under out/. The build that produced the "
            f"deployed bytes is where the compiler settings come from; without "
            f"it this run cannot say what to submit.")
    if len(hits) > 1:
        raise Damaged(f"{len(hits)} artifacts are named {name}: "
                      + ", ".join(hits))
    return hits[0]


def input_for(name: str, art: str, work: str) -> tuple:
    """(standard-json path, settings, 'src/Path.sol:Name', provenance, files)."""
    st, prov = settings_from(art)
    target = st.get("target") or {}
    src = next(iter(target), None)
    if not src:
        # The artifact knows which file it compiled. Without that this would be
        # guessing a path from a contract name, and src/ holds facets in two
        # directories.
        raise Damaged(f"{art} carries no compilationTarget, so the source path "
                      f"of {name} is unknown")
    files = sorted(st.get("sources") or {})
    if not files:
        raise Damaged(f"{art} lists no sources")
    missing = [f for f in files if not os.path.isfile(f)]
    if missing:
        raise Damaged(
            f"{len(missing)} source(s) the deployed metadata names are not in "
            f"this tree: {missing[:4]}")
    os.makedirs(work, exist_ok=True)
    out = os.path.join(work, f"{name}-standard-json-input.json")
    write_standard_json(".", files, st, out, name, src)
    return out, st, f"{src}:{name}", prov, files


# --------------------------------------------------------------------------
# the verdict


def verdict(watchdog_dir: str) -> list:
    """Both watchdogs, one after the other. (name, exit code, tail) each."""
    out = []
    for w in WATCHDOGS:
        path = os.path.join(watchdog_dir, w)
        if not os.path.isfile(path):
            out.append((w, None, f"not found at {path}"))
            continue
        try:
            p = run([path], 1800)
            out.append((w, p.returncode,
                        ((p.stdout or "") + (p.stderr or ""))[-1200:]))
        except subprocess.TimeoutExpired:
            out.append((w, None, "timed out after 1800s"))
    return out


# --------------------------------------------------------------------------


def parse(argv):
    ap = argparse.ArgumentParser(
        prog="press-cut.sh",
        description="Press a diamond cut with the publication and the verdict "
                    "inside the same action.")
    ap.add_argument("script", help="the cut script, e.g. UpgradeFlatPrices")
    ap.add_argument("--press", action="store_true",
                    help="⚠️ RUN THE CUT. Writes to the chain. The owner's "
                         "keypress, never a tool's.")
    ap.add_argument("--after-cut", action="store_true",
                    help="skip the cut; publish and take the verdict from the "
                         "record that already exists")
    ap.add_argument("--allow-untracked", action="store_true",
                    help="proceed although untracked files are present (they "
                         "are listed either way)")
    ap.add_argument("--allow-commit-drift", action="store_true",
                    help="⚠️ publish although the record was not made at this "
                         "HEAD")
    ap.add_argument("--skip-address-oracle", action="store_true",
                    help="⚠️ do not run verify-cut-addresses.sh first")
    ap.add_argument("--no-submit", action="store_true",
                    help="walk everything up to the submission and stop before "
                         "asking the explorer")
    ap.add_argument("--dry-send", action="store_true",
                    help="walk the publication path but withhold the requests")
    ap.add_argument("--trace", metavar="FILE",
                    help="one line per explorer request, written BEFORE it "
                         "leaves")
    ap.add_argument("--explorer-url", default=EXPLORER,
                    help="⚠️ test seam: where the explorer lives")
    ap.add_argument("--watchdog-dir", default="script",
                    help="⚠️ test seam: where the two watchdogs are taken from")
    ap.add_argument("--press-command", metavar="CMD",
                    help="⚠️ TEST SEAM, announced loudly in the output: run "
                         "CMD instead of `forge script --broadcast`. It exists "
                         "for ONE reason -- exit 9, the road where the chain "
                         "has already changed, is the road nobody may rehearse "
                         "by actually changing the chain. It grants no "
                         "capability: whoever can pass this flag can run forge "
                         "directly.")
    ap.add_argument("--work-dir", help="where the compiler inputs are written")
    ap.add_argument("--rpc", default=os.environ.get("RPC_URL") or DEFAULT_RPC)

    # ⚠️ THE SPLIT IS DONE HERE, NOT BY argparse. Measured 31 October 2026: a
    # trailing `nargs="*"` positional does NOT collect `-- --account x`;
    # argparse answers "unrecognized arguments" and the press would die AFTER
    # the owner typed his credentials. Everything after the first `--` is
    # forge's, verbatim, and nothing here interprets it.
    mine, forge_args = argv, []
    if "--" in argv:
        i = argv.index("--")
        mine, forge_args = argv[:i], argv[i + 1:]
    a = ap.parse_args(mine)
    a.forge_args = forge_args
    return a


def main(argv) -> int:
    a = parse(argv)

    name = os.path.basename(a.script)
    if name.endswith(".s.sol"):
        name = name[: -len(".s.sol")]
    sol = os.path.join("script", name + ".s.sol")
    rec = record_path(name)
    work = a.work_dir or os.path.expanduser(
        f"~/hexseal-press/{name}-{time.strftime('%Y%m%d-%H%M%S')}")

    print("=" * 74)
    print(f"PRESS CUT  {name}")
    print("=" * 74)
    if a.explorer_url != EXPLORER:
        print(f"⚠️ NOT THE REAL EXPLORER: {a.explorer_url}")
    if a.watchdog_dir != "script":
        print(f"⚠️ NOT THE REAL WATCHDOGS: {a.watchdog_dir}/")
    if a.press_command:
        print(f"⚠️ NOT THE REAL CUT COMMAND: {a.press_command}")
    if a.press and a.after_cut:
        fail(f"\n{NOT_DONE} -- --press and --after-cut are different jobs; "
             f"pick one.")
        return REFUSED_TO_START

    # ---- 1. the tree
    try:
        tracked, untracked = tree_state()
    except Unmeasurable as exc:
        fail(f"\n{NOT_DONE} -- {exc}")
        return UNMEASURABLE
    head = head_commit()
    print(f"\n[1] THE TREE")
    print(f"    HEAD .................. {(head or '?')[:12]}")
    if tracked:
        print(f"    ✘ {len(tracked)} tracked change(s) NOT COMMITTED:")
        for code, path in tracked:
            print(f"        {code}  {path}")
        say("A cut publishes the sources that are IN THE TREE. If the tree is "
            "not the commit, the sources submitted are not the sources "
            "deployed, and the explorer's refusal arrives long after the chain "
            "has changed. Commit or stash, then press again.", "    ")
        fail(f"\n{NOT_DONE} -- the tree has uncommitted changes. Nothing ran.")
        return REFUSED_TO_START
    print(f"    tracked changes ....... none")
    if untracked:
        print(f"    {len(untracked)} untracked file(s):")
        for _code, path in untracked:
            print(f"        ?? {path}")
        if not a.allow_untracked:
            say("An untracked file can be imported by a committed one, and then "
                "the build used a file no commit holds. Pass --allow-untracked "
                "if you have read the list above.", "    ")
            fail(f"\n{NOT_DONE} -- untracked files present. Nothing ran.")
            return REFUSED_TO_START
        print(f"    (allowed by --allow-untracked)")
    else:
        print(f"    untracked files ....... none")

    if not os.path.isfile(sol):
        fail(f"\n{NOT_DONE} -- no cut script at {sol}")
        return REFUSED_TO_START

    # ---- 2. the cut
    cut_landed = False
    if a.press:
        if any(x == "--verify" for x in a.forge_args):
            say("⚠️ --verify was passed through to forge. Its answer is NOT a "
                "verdict here (two verifiers, exit 0 almost always); this run "
                "takes the verdict from the two watchdogs either way. "
                "Harmless, but do not read forge's line as the result.", "    ")
        before = time.time()
        cmd = cut_command(sol, a.forge_args)
        print(f"\n[2] THE CUT (this run writes to the chain)")
        # ⚠️ The REDACTED form, always. The list above runs with real values;
        # this line is the only thing a reader or a log ever gets.
        print("    " + printable_command(sol, a.forge_args))
        if a.forge_args:
            print(f"    (NOT ONE of those {len(a.forge_args)} arguments is "
                  f"printed, in any form -- the shell has already turned "
                  f"$PRIVATE_KEY into the key itself by the time this script "
                  f"starts, and this output is usually piped into a log.)")
        sys.stdout.flush()
        if a.press_command:
            prog = (a.press_command.split() or ["?"])[0]
            rest = len(a.press_command.split()) - 1
            print(f"    ⚠️⚠️ THAT LINE DID NOT RUN. A rehearsal command was "
                  f"supplied instead -- `{prog}` + {rest} token(s), not "
                  f"printed -- so NOTHING was sent to the chain.")
            sys.stdout.flush()
            p = subprocess.run(["bash", "-c", a.press_command])
        else:
            p = subprocess.run(cmd)
        fresh = os.path.isfile(rec) and os.path.getmtime(rec) > before
        who = "the rehearsal command" if a.press_command else "forge"
        print(f"    {who} exited {p.returncode}; a new record was "
              f"{'written' if fresh else 'NOT written'}")
        if p.returncode != 0 and not fresh:
            fail(f"\n{NOT_DONE} -- the cut did not run and no record was "
                 f"written. The chain was not touched.")
            return REFUSED_TO_START
        if not fresh:
            # ⚠️ Measured road, not a hypothetical: the cut command exits 0 and
            # writes nothing (a cut that turns out to be a no-op, a simulation,
            # a script that broadcast no transaction). The record still on disk
            # belongs to an EARLIER cut, and publishing from it would mean this
            # press reporting work it did not do -- the quiet "almost worked"
            # that decision 250 names as worse than an honest failure.
            say("⚠️ THE CUT COMMAND SUCCEEDED AND WROTE NO RECORD. This press "
                "therefore has nothing of its own to publish, and the record "
                "sitting on disk is an earlier cut's. Nothing is published "
                "from it: a press must not report a publication it did not "
                "perform. If working on an existing record is what you "
                "actually want, that is --after-cut, and it says so.", "    ")
            fail(f"\n{NOT_DONE} -- no record was written by this press.")
            return DAMAGED
        cut_landed = fresh
        if p.returncode != 0 and fresh:
            say("⚠️ forge FAILED and still wrote a record: part of the cut may "
                "be on the chain. Continuing to the publication, and this run "
                "cannot end green.", "    ")
    elif a.after_cut:
        print(f"\n[2] THE CUT was not pressed here (--after-cut).")
    else:
        # ---- the default road: prepare, hand over ONE LINE, publish nothing.
        print(f"\n[2] NOTHING WAS PRESSED AND NOTHING WAS PUBLISHED.")
        say("Writing to the chain is the owner's keypress, so this road stops "
            "here by design. The line below does the cut, the publication and "
            "the verdict in ONE action -- which is the whole point: a "
            "publication that is a separate action is a publication that gets "
            "forgotten, four times in three weeks.", "    ")
        if os.path.isfile(rec):
            old = (time.time() - os.path.getmtime(rec)) / 3600
            print(f"\n    a record for {name} already exists, written "
                  f"{old:.1f} h ago. After the press it must be NEWER than the "
                  f"press itself -- this script checks that rather than "
                  f"trusting the file to be the right one.")
        else:
            print(f"\n    no record for {name} yet: {rec}")
        print(f"\n    ONE LINE, for the owner (cut -> publish -> verdict):")
        print(f"\n      ./script/press-cut.sh {name} --press -- "
              f"--account <keystore> --rpc-url \"$BASE_SEPOLIA_RPC_URL\"\n")
        say("⚠️ A KEYSTORE (--account, or --keystore) IS THE FORM TO USE. A "
            "key on a command line is read by the process list, the shell "
            "history and every crash log on the way past -- and the shell "
            "expands $PRIVATE_KEY before this script sees anything, so what "
            "arrives here is the key itself. If you type one anyway, this run "
            "will NOT print it: no pass-through argument is printed at all, "
            "only how many there were, so nothing of it reaches the terminal "
            "or a log file. The protection is this script's; the process list "
            "is still not.", "    ")
        say("--verify is deliberately NOT in that line: forge's verification "
            "answer is not a verdict here.", "    ")
        print(f"\n    to rehearse everything AFTER a cut on a record that "
              f"already exists, with no chain write at all:")
        print(f"\n      ./script/press-cut.sh {name} --after-cut --no-submit\n")
        print(f"{NOT_DONE} -- prepared only (exit 0 means prepared, never "
              f"published).")
        return OK

    # ---- 3. the record and its addresses
    try:
        doc = read_record(rec)
        made = creates(doc)
        findings, counts = cross_check(doc, made)
    except Damaged as exc:
        fail(f"\n[3] DAMAGED: {exc}")
        fail(f"\n{NOT_DONE} -- the record cannot be used.")
        return CUT_LANDED_UNPUBLISHED if cut_landed else DAMAGED
    age = (time.time() - os.path.getmtime(rec)) / 60
    print(f"\n[3] THE RECORD, and the addresses BY TRANSACTION TYPE")
    print(f"    {rec}")
    print(f"    written ............... {age:.1f} min ago")
    print(f"    CREATE transactions ... {counts['transactions']}")
    print(f"    creation receipts ..... {counts['receipts']}")
    print(f"    named in the cut ...... {counts['named_in_cut']} "
          f"(of {counts['cut_calldata_bytes']} bytes of call data)")
    for c in made:
        print(f"      {c['address']}  {c['name']}")
    if not made:
        say("This record created nothing. A cut that only removes selectors "
            "has nothing to publish, and that is a legitimate green -- but it "
            "is reported as 'nothing to publish', never as 'published'.",
            "    ")
    if findings:
        print(f"\n    ✘ THE RECORD DISAGREES WITH ITSELF:")
        for f in findings:
            say(f, "      ")
        fail(f"\n{NOT_DONE} -- would publish {counts['transactions']} of "
             f"{max(counts['receipts'], counts['named_in_cut'])}. "
             f"Nothing was published.")
        return CUT_LANDED_UNPUBLISHED if cut_landed else DAMAGED
    if made:
        print(f"    ✔ the receipts and the cut's own call data name the same "
              f"addresses")

    label = doc.get("commit")
    print(f"    commit label by forge . {str(label)[:12]!r}", end="")
    if not label or not object_exists(str(label)):
        print(" -- ⚠️ not an object in this repository; cannot be compared")
    elif head and not head.startswith(str(label)):
        print(" -- ✘ NOT THIS HEAD")
        say("The tree has moved since the cut, so the sources here are not the "
            "sources deployed. --allow-commit-drift submits anyway.", "    ")
        if not a.allow_commit_drift:
            fail(f"\n{NOT_DONE} -- the record was made at another commit.")
            return CUT_LANDED_UNPUBLISHED if cut_landed else DAMAGED
    else:
        print(" -- ✔ this HEAD")

    # ---- 4. the address oracle: does each name sit on its own body
    if not made:
        print(f"\n[4] ADDRESS ORACLE not needed: nothing was created.")
    elif a.skip_address_oracle:
        print(f"\n[4] ADDRESS ORACLE SKIPPED (--skip-address-oracle). NOT a "
              f"pass -- it was not asked. Whether each name belongs to the "
              f"address next to it is unknown on this road.")
    elif not os.path.isfile("./script/verify-cut-addresses.sh"):
        # ⚠️ This happens in the PUBLIC SHOWCASE TREE, not only in a broken
        # checkout: the showcase carries the publication instruments and does
        # not carry verify-cut-addresses.*, so the oracle is simply absent
        # there. An absent oracle is "could not measure", never "agreed", and
        # it must not be a traceback either -- subprocess on a missing file
        # raises, and a traceback is a refusal nobody can act on.
        say("⚠️ ./script/verify-cut-addresses.sh IS NOT IN THIS TREE, so "
            "whether each name belongs to the address next to it cannot be "
            "asked here. That is not a pass. Either run this from a tree that "
            "has it, or pass --skip-address-oracle and accept that the "
            "weakest link of the submission is unchecked.", "    ")
        fail(f"\n[4] ADDRESS ORACLE MISSING -- not asked, not passed.")
        fail(f"\n{NOT_DONE} -- the address oracle is not in this tree.")
        return CUT_LANDED_UNPUBLISHED if cut_landed else UNMEASURABLE
    else:
        print(f"\n[4] ADDRESS ORACLE: ./script/verify-cut-addresses.sh {name}")
        p = run(["./script/verify-cut-addresses.sh", name], 900)
        print(((p.stdout or "") + (p.stderr or ""))[-1200:])
        print(f"    verify-cut-addresses.sh exited {p.returncode}")
        if p.returncode != 0:
            say("The names in this record do not provably belong to the "
                "addresses next to them, so a submission could put one "
                "contract's source on another's address -- which is exactly "
                "what happened on 29 September 2026, five addresses out of "
                "nine. Nothing is submitted.", "    ")
            fail(f"\n{NOT_DONE} -- the address oracle did not agree.")
            if cut_landed:
                return CUT_LANDED_UNPUBLISHED
            return DAMAGED if p.returncode in (1, 2) else UNMEASURABLE

    # ---- 5. the compiler inputs
    inputs = []
    if made:
        print(f"\n[5] WHAT WOULD BE SUBMITTED")
    for c in made:
        try:
            art = artifact_for(c["name"])
            inp, st, target, prov, files = input_for(c["name"], art, work)
        except Damaged as exc:
            fail(f"    ✘ {c['name']}: {exc}")
            fail(f"\n{NOT_DONE} -- cannot build the submission for "
                 f"{c['name']}.")
            return CUT_LANDED_UNPUBLISHED if cut_landed else DAMAGED
        except Unmeasurable as exc:
            fail(f"    ✘ {c['name']}: {exc}")
            fail(f"\n{NOT_DONE} -- cannot build the submission for "
                 f"{c['name']}.")
            return CUT_LANDED_UNPUBLISHED if cut_landed else UNMEASURABLE
        inputs.append((c, inp, st, target))
        print(f"    {c['name']}")
        print(f"      address ........... {c['address']}")
        print(f"      target ............ {target}")
        print(f"      settings from ..... {prov}")
        print(f"      settings .......... solc {st['solc']}, viaIR "
              f"{st['viaIR']}, evm {st['evmVersion']}, optimizer "
              f"{st['optimizer']}, bytecodeHash {st['bytecodeHash']}")
        print(f"      sources ........... {len(files)} file(s)")
        print(f"      input ............. {inp} "
              f"({os.path.getsize(inp)} bytes)")

    # ---- 6. the publication
    key, keyfrom = None, None
    if inputs and not a.no_submit:
        try:
            from check_sources_published import api_key
            key, keyfrom = api_key()
        except Exception as exc:  # noqa: BLE001 -- reported, never raised
            print(f"    (the gate's key lookup was unavailable: {exc})")
            key, keyfrom = os.environ.get("ETHERSCAN_API_KEY"), "environment"
    results = []
    if not inputs:
        print(f"\n[6] nothing to publish. The verdict is still taken, because "
              f"'this cut added nothing' is not 'everything is published'.")
    elif a.no_submit:
        print(f"\n[6] --no-submit: the explorer was NOT asked at all. Nothing "
              f"was published by this run.")
    elif not key:
        fail(f"\n[6] NO EXPLORER KEY. Nothing was submitted, and a missing key "
             f"is not a pass.")
        fail(f"\n{NOT_DONE} -- no explorer key.")
        return CUT_LANDED_UNPUBLISHED if cut_landed else UNMEASURABLE
    else:
        print(f"\n[6] PUBLISHING {len(inputs)} source(s). Key from {keyfrom}; "
              f"its value is never printed.")
        ex = Explorer(a.explorer_url, key, a.trace, a.dry_send)
        for c, inp, st, target in inputs:
            print(f"    {c['name']} -> {c['address']}")
            payload = {
                "chainid": CHAIN_ID,
                "module": "contract",
                "action": "verifysourcecode",
                "codeformat": "solidity-standard-json-input",
                "sourceCode": open(inp, encoding="utf-8").read(),
                "contractaddress": c["address"],
                "contractname": target,
                "compilerversion": "v" + str(st["solc"]),
            }
            try:
                resp = ex.post(payload)
            except Unmeasurable as exc:
                fail(f"      COULD NOT REACH THE EXPLORER: {exc}")
                results.append((c, "unreachable", str(exc)))
                continue
            kind, detail = classify_submit(resp)
            print(f"      submission: {kind} -- {str(detail)[:160]}")
            if kind != "accepted":
                results.append((c, kind, detail))
                continue
            final = ("pending", "the ticket was never polled")
            for i in range(POLL_TRIES):
                time.sleep(POLL_PAUSE)
                try:
                    st_resp = ex.get({"chainid": CHAIN_ID,
                                      "module": "contract",
                                      "action": "checkverifystatus",
                                      "guid": detail})
                except Unmeasurable as exc:
                    print(f"      could not poll: {exc}")
                    final = ("unreachable", str(exc))
                    break
                k, d = classify_status(st_resp)
                print(f"      poll {i + 1}: {k} -- {str(d)[:140]}")
                final = (k, d)
                if k in ("verified", "already", "failed", "refused"):
                    break
            results.append((c, final[0], final[1]))
        print(f"    {ex.sent} request(s) left this machine.")

    if results:
        print(f"\n    what the explorer ANSWERED -- this is the builder "
              f"talking, and it is NOT the verdict:")
        for c, kind, d in results:
            print(f"      {kind:12} {c['name']} {c['address']}  {str(d)[:80]}")

    # ---- 7. THE VERDICT
    print(f"\n[7] THE VERDICT, from BOTH watchdogs, one after the other")
    rows = verdict(a.watchdog_dir)
    for w, code, tail in rows:
        print(f"    -- {w} --")
        print(tail)
        print(f"    {w} exited {code}")
    green = [r for r in rows if r[1] == 0]
    print(f"    {len(green)} of {len(rows)} watchdog(s) say yes")

    withheld = [c for c, k, _d in results if k == "dry"]
    deferred = [c for c, k, _d in results if k in ("pending", "unknown")]
    # A submission answer is a VETO, never a pass -- see the header. Anything
    # that is not "the explorer says this source is on this address" keeps the
    # run red, because the two rosters the watchdogs read may not name this
    # contract at all.
    bad = [(c, k) for c, k, _d in results
           if k not in ("verified", "already")]

    if len(rows) == len(WATCHDOGS) and len(green) == len(rows) and not bad:
        # The ONLY road to the one success sentence, and the watchdogs are
        # what grants it: a submission that answered "verified" while a
        # watchdog says no ends at exit 8, which is the whole second half of
        # decision 250.
        if not results:
            print(f"\n{DONE} -- BOTH watchdogs agree. ⚠️ Nothing was submitted "
                  f"in THIS run (nothing to publish, or --no-submit), so what "
                  f"this states is that the explorer already holds every "
                  f"source the two rosters name.")
            return OK
        print(f"\n{DONE} -- the cut is published and BOTH watchdogs agree.")
        return OK

    # ---- 8. not done, and WHICH KIND of not done
    reasons = []
    for w, code, _t in rows:
        if code == 0:
            continue
        if code is None:
            reasons.append(f"{w} could not be run")
        elif code == 1:
            reasons.append(f"{w} says NO (exit 1)")
        else:
            reasons.append(f"{w} COULD NOT MEASURE (exit {code})")
    for c, kind in bad:
        reasons.append(f"{c['name']} {kind.upper()} at the explorer")
    if withheld:
        say("The requests were WITHHELD (--dry-send), so nothing was "
            "published by this run. Whatever the watchdogs answered is their "
            "statement about the state BEFORE this run, not its result.",
            "    ")
    if deferred:
        say("⚠️ DEFERRED IS NOT PUBLISHED -- AND IT IS NOT A REFUSAL EITHER. "
            "The explorer TOOK " + ", ".join(c["name"] for c in deferred) +
            " and has not finished verifying. The watchdog reads the explorer, "
            "so it answers 'no source' until that queue clears. That is a "
            "different sentence from 'the explorer refused the source', and it "
            "is printed as a different one, with its own exit code 7. Re-take "
            "the verdict in a few minutes; the sources are already with the "
            "explorer and must NOT be submitted again.", "    ")
    fail(f"\n{NOT_DONE} -- " + "; ".join(reasons or ["see above"]))

    if cut_landed:
        fail("=" * 74)
        fail("⚠️  THE CUT IS ON THE CHAIN AND THE SOURCES ARE NOT UP.")
        fail("=" * 74)
        say_err("This run changed the chain and could not finish the "
                "publication. A press cannot be un-pressed: nothing here will "
                "retry it, and nobody else is watching. Finish it with ONE "
                "LINE -- it does NOT cut again, it reads the record this run "
                "wrote, publishes, and takes the verdict:")
        fail(f"\n      ./script/press-cut.sh {name} --after-cut\n")
        if deferred:
            say_err("If the only complaint above was the queue, that is also "
                    "the right line: it re-takes the verdict without "
                    "resubmitting anything the explorer already holds.")
        return CUT_LANDED_UNPUBLISHED

    # Not pressed in this run: the specific reason survives as the exit code.
    if deferred:
        return QUEUED
    for _c, kind, _d in results:
        if kind in ("refused", "failed"):
            return REFUSED
        if kind in ("unreachable", "ratelimited"):
            return UNREACHABLE
    if withheld:
        return UNMEASURABLE
    if results and all(k in ("verified", "already") for _c, k, _d in results):
        return CONTRADICTED
    if any(code != 1 for _w, code, _t in rows):
        return UNMEASURABLE
    return CONTRADICTED if results else UNMEASURABLE


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        fail(f"\n{NOT_DONE} -- interrupted.")
        sys.exit(UNMEASURABLE)
