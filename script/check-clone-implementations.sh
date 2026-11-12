#!/usr/bin/env bash
# Gate: every Agreement implementation that a LIVE CLONE actually executes has
# its source published on the block explorer.
#
# Its neighbour `check-sources-published.sh` asks the deployer for its CURRENT
# implementation. That is the right question about the next deal and blind to
# every deal that already exists: an EIP-1167 clone carries the implementation
# address in its own body and never changes it, so each swap leaves one more
# generation running the old one for ever.
#
# The whole argument -- why the roster is read from the registry's own array
# rather than from the subgraph or from event logs, what the storage read is
# guarded against, and what this gate cannot see -- is the docstring of
# script/check_clone_implementations.py. It is not repeated here, so that there
# is one copy of it.
#
# ⚠️ NOT PART OF THE DEPLOY PREFLIGHT, and deliberately. It needs the network
# and an explorer key; a deploy touches no chain and must not start failing
# because an explorer was rate-limiting. Where it should hang instead is the
# owner's call.
#
# Usage:
#   ./script/check-clone-implementations.sh
#
# Environment:
#   ETHERSCAN_API_KEY / BASESCAN_API_KEY   the explorer key. Taken from the
#                                          environment, else from ./.env, by the
#                                          neighbour's own lookup. The value is
#                                          never printed.
#   RPC_URL                                default https://sepolia.base.org.
#                                          The dRPC key is IP-locked to the
#                                          server, so the public endpoint is the
#                                          one that answers here.
#
# Exit codes:
#   0    every implementation a live clone runs is published
#   1    at least one is not -- named, with the clones that run it
#   2    DAMAGED. The censuses disagree about the diamond, the registry's
#        storage layout no longer matches what this reads, the roster is empty,
#        or an address on it is not an EIP-1167 clone. Nothing was measured.
#   3    COULD NOT MEASURE -- no key, no network, the explorer refused or
#        rate-limited, or a chain read failed. NOT a pass.
#   127  python3 or cast not found
#
# ⚠️ READ-ONLY. `cast call`, `cast keccak`, `eth_getCode` and
# `eth_getStorageAt`. This gate never writes to the chain, and it sends nothing
# anywhere except the explorer query.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

if ! command -v python3 >/dev/null 2>&1; then
    echo "check-clone-implementations: python3 not found" >&2
    exit 127
fi
# `cast` decodes the registry's getters and hashes the array slot. Doing either
# by hand would mean hardcoding selectors and a keccak implementation, i.e.
# exactly the kind of literal these gates exist to avoid.
if ! command -v cast >/dev/null 2>&1; then
    echo "check-clone-implementations: cast not found (foundry)" >&2
    exit 127
fi

python3 script/check_clone_implementations.py "$@"
