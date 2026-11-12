#!/usr/bin/env bash
# Press a diamond cut with the PUBLICATION and the VERDICT inside the same
# action.
#
# The whole argument -- why publication stopped being a separate step, where
# the addresses come from and why they are cross-checked against two other
# sides of the same record, why the verdict is taken from two watchdogs and
# never from the submission's own answer, and what each exit code means -- is
# the docstring of script/press_cut.py. It is not repeated here, so that there
# is one copy of it.
#
# ⚠️ THE CUT IS THE OWNER'S KEYPRESS. A run without --press writes nothing
# anywhere: it checks the tree, then prints ONE READY LINE for him and stops.
# Everything that happens AFTER a cut -- reading the record, publishing,
# taking the verdict -- is reachable on its own with --after-cut against a
# record that already exists, and that is how this script was accepted: the
# second half is provable without a single byte going to the chain.
#
# ⚠️ --verify IS NOT PASSED TO forge, deliberately. It asks two verifiers,
# prints the tail of one and exits 0 almost always. This script publishes the
# sources itself and then READS the explorer back through two gates.
#
# ⚠️ A CREDENTIAL ON THE COMMAND LINE IS NEVER PRINTED BACK. The shell expands
# `"$PRIVATE_KEY"` before this script starts, so what arrives is the key
# itself; the command that runs and the command that is shown are built
# separately, and NOT ONE pass-through argument appears in the shown one -- only
# how many there were. That matters most because this output is usually piped
# into a run log, and a key that reached a log cannot be taken out of it. Use a
# keystore (--account) anyway: this protects the log, not the process list.
#
# Usage:
#   ./script/press-cut.sh <Script>
#       check the tree and print the owner's one line. Nothing else.
#
#   ./script/press-cut.sh <Script> --press -- <forge credential flags>
#       ⚠️ WRITES TO THE CHAIN: cut, publish every created contract, verdict.
#
#   ./script/press-cut.sh <Script> --after-cut
#       the second half only, on the record that already exists. This is also
#       the line printed on exit 9 to finish a press that fell over.
#
#   Options (the loud ones announce themselves in the output):
#     --allow-untracked       proceed although untracked files are present
#     --allow-commit-drift    ⚠️ publish although the record is not this HEAD
#     --skip-address-oracle   ⚠️ do not run verify-cut-addresses.sh first
#     --no-submit             stop before asking the explorer
#     --dry-send              walk the publication path, withhold the requests
#     --trace FILE            one line per explorer request, written BEFORE it
#                             leaves
#     --explorer-url URL      ⚠️ test seam
#     --watchdog-dir DIR      ⚠️ test seam
#     --work-dir DIR          where the compiler inputs are written
#
# Environment:
#   ETHERSCAN_API_KEY / BASESCAN_API_KEY   the explorer key, looked up by the
#                                          publication gate's own function.
#                                          The value is never printed.
#   RPC_URL                                default https://sepolia.base.org.
#                                          The dRPC key is IP-locked to the
#                                          server, so the public endpoint is
#                                          the one that answers here.
#
# Exit codes (the full wording is in the python docstring):
#   0    prepared, or published AND both watchdogs exit 0
#   1    REFUSED TO START -- dirty tree, no such script, nothing ran
#   2    DAMAGED -- the record contradicts itself or the tree. Nothing published
#   3    COULD NOT MEASURE -- no key, no artifact, a gate could not ask
#   5    the explorer REFUSED a source
#   6    the explorer was UNREACHABLE or rate-limited us
#   7    ACCEPTED AND STILL QUEUED -- deferred, NOT published
#   8    the explorer said verified and a WATCHDOG DISAGREES
#   9    ⚠️ THE CUT LANDED AND THE PUBLICATION DID NOT FINISH -- the chain has
#        changed, a human has to come back, and the line to finish it is in the
#        output
#   127  python3, git, cast or forge not found
set -uo pipefail

# Paths are made absolute BEFORE the cd below, so that an argument typed
# relative to wherever the caller stands keeps pointing at the same file.
args=()
want_path=0
for arg in "$@"; do
    if [ "$want_path" = 1 ]; then
        args+=("$(realpath -m -- "$arg")")
        want_path=0
        continue
    fi
    case "$arg" in
        --trace|--work-dir) want_path=1 ;;
    esac
    args+=("$arg")
done

cd "$(dirname "$0")/.." || exit 1

# forge is needed only on the --press road, but it is checked here either way:
# a press that discovers a missing tool AFTER the chain has changed is the one
# failure this script exists to make impossible.
for tool in python3 git cast forge; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "press-cut: $tool not found" >&2
        exit 127
    fi
done

# ── What we owe that THIS cut could pay ──────────────────────────────────────
#
# A deferral written in prose cannot remind anybody of itself at the one minute
# it becomes payable. On 2 November 2026 answering "what did we defer until the
# next cut?" took eleven searches across 48 000 lines, and one answer was three
# days out of date. script/owed.tsv is that question as a table a machine
# reads; this is the minute to read it.
#
# ⚠️ IT PRINTS AND GOES ON. No question, no refusal. The owner is the one
# pressing, and a prompt in the middle of a cut costs more than it buys — so
# the refusing half lives in script/check-owed.sh, which CI and the deploy
# preflight run. `|| true` is deliberate and not laziness: the only thing that
# must never happen here is a cut blocked by its own reminder.
#
# Held to this by script/check_owed.py (WIRING): delete the call and that gate
# goes red by name.
#
# ⚠️ THE REGISTER DOES NOT TRAVEL TO THE PUBLIC SHOWCASE and neither does its
# gate: a list of the guards we have NOT built yet is the owner's to publish,
# not this script's. So the absence of the file is a normal state out there and
# is said in one line rather than left as a bare "No such file or directory".
if [ -x ./script/check-owed.sh ]; then
    ./script/check-owed.sh --print cut || true
else
    echo "── what we owe that a cut can pay: no register in this tree (it is kept out of the public export)"
fi

# -u: this output is almost always read through a pipe (a tee into a run log).
# Block-buffered stdout against unbuffered stderr puts the refusals ABOVE the
# step they refused, which is how a reader ends up blaming the wrong step.
python3 -u script/press_cut.py "${args[@]}"
