#!/usr/bin/env bash
# Rebuild an Agreement implementation whose source has left the tree, and
# publish it -- but only behind an oracle that compares the rebuild with OUR
# OWN byte record of the deployment.
#
# The whole argument -- why the commit label `forge` wrote is unusable, why the
# rebuild is a `solc --standard-json` call on one file rather than a
# `forge build`, why the verdict comes from the watchdog and not from the
# submission, and what this cannot do -- is the docstring of
# script/publish_archived_implementation.py. It is not repeated here, so that
# there is one copy of it.
#
# ⚠️ THE BUILD STEP IS NOT RUN FROM HERE. A full via_ir compilation of this
# tree peaks around 12 GB and outlives any single tool call; this project has
# lost executors mid-work to exactly that. So a run without --built stops after
# writing the compiler input and printing ONE READY LINE for the owner, and
# everything after the build -- oracle, publication, verdict -- takes the built
# artifact as an ARGUMENT. Both branches of the oracle are therefore provable
# by substitution with no compile at all.
#
# Usage:
#   ./script/publish-archived-implementation.sh <address> [options]
#
#   --settings-from PATH  a recorded build (forge artifact, metadata JSON, or
#                         solc output) to lift the compiler settings from
#   --work-dir DIR        where the archived commit is extracted
#   --built PATH          the already-built creation code: solc output JSON, a
#                         forge artifact, or a plain hex dump
#   --submit              send the source to the explorer; reached ONLY on an
#                         exact byte-for-byte match
#   --dry-send            walk the publication path but withhold the request
#   --trace FILE          one line per explorer request, written BEFORE the
#                         request leaves. Never the key, never the body.
#   --explorer-url URL    ⚠️ test seam; a non-default value is announced loudly
#   --offline             skip the chain cross-check
#   --no-verdict          do not run the watchdog after publishing
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
# Exit codes:
#   0    prepared, or the oracle matched, or published and the watchdog agrees
#   2    DAMAGED. No record of this address, records that disagree, the record
#        is not a CREATE, or the candidate commit has submodules this cannot
#        materialise. Nothing was measured.
#   3    COULD NOT MEASURE -- unreadable build output, no explorer key, the
#        watchdog could not ask. NOT a pass.
#   4    THE ORACLE SAID NO. The rebuild is not these bytes, and the explorer
#        was not asked at all.
#   5    the explorer REFUSED the source, or could not verify it
#   6    the explorer was unreachable or rate-limited us
#   7    the explorer TOOK the source and has not verified it yet -- this is
#        not "published", and it is deliberately not exit 0
#   8    the explorer said verified and the WATCHDOG DISAGREES
#   127  python3, git, cast or tar not found
#
# ⚠️ WRITES NOTHING TO THE CHAIN. It reads the deployed code once (skippable),
# talks to the explorer, extracts a commit into a directory of its own, and
# never touches the working tree.
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
        --built|--trace|--settings-from|--work-dir) want_path=1 ;;
    esac
    args+=("$arg")
done

cd "$(dirname "$0")/.." || exit 1

for tool in python3 git cast tar; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "publish-archived-implementation: $tool not found" >&2
        exit 127
    fi
done

# -u: this script's output is almost always read through a pipe (a tee into a
# run log). Block-buffered stdout against unbuffered stderr puts the refusals
# ABOVE the step they refused, which is how a reader ends up blaming the wrong
# step.
python3 -u script/publish_archived_implementation.py "${args[@]}"
