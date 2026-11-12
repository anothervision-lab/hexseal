#!/usr/bin/env bash
# Gate: every contract of the LIVE protocol has its source published on the
# block explorer.
#
# The whole argument -- why it exists, why the roster is read from the chain
# instead of listed here, what "published" does NOT mean, and why a missing key
# is red rather than green -- is the docstring of
# script/check_sources_published.py. It is not repeated here, so that there is
# one copy of it.
#
# Usage:
#   ./script/check-sources-published.sh
#
# Environment:
#   ETHERSCAN_API_KEY / BASESCAN_API_KEY   the explorer key. Taken from the
#                                          environment, else from ./.env.
#                                          The value is never printed.
#   RPC_URL                                default https://sepolia.base.org.
#                                          The dRPC key is IP-locked to the
#                                          server, so the public endpoint is
#                                          the one that answers here.
#
# Exit codes:
#   0    every contract on the roster is published
#   1    at least one is not -- named, with its address and how it was found
#   2    the committed censuses are missing or disagree about the diamond proxy.
#        Nothing was measured.
#   3    COULD NOT MEASURE -- no key, no network, the explorer refused or
#        rate-limited, or a chain read failed. NOT a pass.
#   127  python3 or cast not found
#
# ⚠️ READ-ONLY. `cast call` and `eth_getCode` only. This gate never writes to
# the chain, and it never sends anything anywhere except the explorer query.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

if ! command -v python3 >/dev/null 2>&1; then
    echo "check-sources-published: python3 not found" >&2
    exit 127
fi
# cast decodes the loupe's return value and every getter's. Doing that by hand
# would mean hardcoding four-byte selectors, i.e. exactly the kind of literal
# this gate exists to avoid.
if ! command -v cast >/dev/null 2>&1; then
    echo "check-sources-published: cast not found (foundry)" >&2
    exit 127
fi

python3 script/check_sources_published.py "$@"
