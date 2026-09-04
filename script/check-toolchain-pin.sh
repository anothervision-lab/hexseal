#!/usr/bin/env bash
# Gate: the build toolchain is pinned, in CI and in foundry.toml, to ONE
# named version -- and the forge actually on PATH is that version.
#
# WHY THIS GATE EXISTS (measured 1 Sept 2026, from the CI logs, not recalled):
#
#   26 Aug 23:44  contracts job GREEN   forge 1.7.1, solc 0.8.35, 1279/1279
#   27 Aug 12:30  foundry v1.8.0 published
#   27 Aug 12:37  contracts job RED     forge 1.8.0, solc 0.8.36, 9 failures
#
# Seven minutes, and no commit of ours in between. The workflow asked
# foundry-toolchain for "stable" and got a different compiler and a different
# EVM harness. It then stayed red for 97 consecutive runs, which means every
# gate BEHIND `forge test` in that job -- both storage layouts, the Agreement
# layout, the ERC-2771 rule, the appeal window, the submodule pins, the
# internal refs, the decisions log -- stopped running entirely. A drifting
# toolchain does not merely make one step red; it silently unplugs the locks
# standing behind it.
#
# What actually moved the numbers was `isolate`, whose default forge 1.8
# flipped from false to true: in isolate mode each top-level call in a test is
# executed as its own transaction and pays the 21_000 intrinsic gas an inner
# call never pays in production. Measured on this tree, only the flag moved:
# getFeeBps() 5_353 -> 31_417, notifyWorkHandedIn() 11_446 -> 37_510. Not one
# call got dearer; the ruler changed.
#
# WHERE THE EXPECTED VALUES COME FROM. They are literals HERE, fixed by hand.
# They are deliberately NOT read out of ci.yml or foundry.toml: a gate that
# derives what it expects from the thing it checks agrees with itself always
# and can never fail (docs/PROCESS.md, the mirror). Changing the toolchain is
# meant to cost one edit in this file, made on purpose.
#
# EXPECTED_SOLC is not a taste. Read from Base Sepolia on 1 Sept 2026, the
# Agreement implementation shipped by the 31 Aug cut
# (0x5863fac389cf26d4234e3abc173ad4ba87ad7021) ends in `64736f6c6343 00081f`
# -- the CBOR metadata for solc 0.8.31. Tests that measure gas against a
# compiler the chain does not run measure bytecode that exists nowhere.
#
# Usage:  ./script/check-toolchain-pin.sh     (exit 0 pass, 1 fail, 3 cannot check)
set -euo pipefail

EXPECTED_FORGE_TAG="v1.8.1"     # what CI installs
EXPECTED_FORGE_VER="1.8.1"      # what `forge --version` must report
EXPECTED_SOLC="0.8.31"          # == the solc in the deployed bytecode
EXPECTED_EVM="prague"           # == what the deployed bytecode was built under
EXPECTED_ISOLATE="false"        # == the model the cap literals were derived under

CI=".github/workflows/ci.yml"
TOML="foundry.toml"
fail=0

for f in "$CI" "$TOML"; do
  if [[ ! -f "$f" ]]; then
    echo "❌ $f not found (cwd: $(pwd)) — run this gate from the repository root"
    exit 3
  fi
done

# ---- 1. CI pins the foundry version explicitly -----------------------------
# Anchored to the `version:` key so a mention inside a comment cannot satisfy
# it: comment lines begin with `#` after their indent and never match.
if ! LC_ALL=C command grep -qaE "^[[:space:]]+version:[[:space:]]*${EXPECTED_FORGE_TAG}[[:space:]]*$" "$CI"; then
  echo "❌ $CI does not pin foundry to ${EXPECTED_FORGE_TAG}."
  echo "   Expected a line 'version: ${EXPECTED_FORGE_TAG}' under the foundry-toolchain step."
  echo "   Without it the action installs whatever is 'stable' that day — which is"
  echo "   exactly how the contracts job went red for 97 runs from 27 Aug 2026."
  fail=1
fi

# Pinning the action by SHA is necessary but NOT sufficient, and the gate says
# so out loud, because that is the mistake that looked like protection.
if ! LC_ALL=C command grep -qa "foundry-rs/foundry-toolchain@[0-9a-f]\{40\}" "$CI"; then
  echo "❌ $CI does not pin the foundry-toolchain ACTION by commit SHA."
  fail=1
fi

# ---- 2. foundry.toml pins the semantics ------------------------------------
# `forge --version` alone does not fix the numbers: solc, evm_version and
# isolate all have per-version defaults. Anchored at line start so a value
# quoted inside a comment does not count.
check_toml() {
  local key="$1" want="$2" pattern
  pattern="^${key}[[:space:]]*=[[:space:]]*\"?${want}\"?[[:space:]]*$"
  if ! LC_ALL=C command grep -qaE "$pattern" "$TOML"; then
    echo "❌ $TOML does not pin ${key} = ${want}"
    echo "   Found: $(LC_ALL=C command grep -aE "^${key}[[:space:]]*=" "$TOML" || echo '(nothing)')"
    fail=1
  fi
}
check_toml solc        "$EXPECTED_SOLC"
check_toml evm_version "$EXPECTED_EVM"
check_toml isolate     "$EXPECTED_ISOLATE"

# ---- 3. the forge on PATH is the pinned one --------------------------------
# The half that CI cannot check for you. On 1 Sept 2026 this repository was
# green locally on forge 1.5.0-dev and red in CI on 1.8.1, with the SAME
# commit and the same 1467 tests — and the split is the reason nobody could
# reproduce the failure for five days.
if ! command -v forge >/dev/null 2>&1; then
  echo "❌ forge is not on PATH — cannot verify the local toolchain"
  exit 3
fi
actual="$(forge --version 2>/dev/null | LC_ALL=C command grep -aoE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+)?' | head -1 || true)"
if [[ "$actual" != "$EXPECTED_FORGE_VER" ]]; then
  echo "❌ local forge is '${actual:-unknown}', pinned is ${EXPECTED_FORGE_VER}."
  echo "   Install it:  curl -L https://foundry.paradigm.xyz | bash && foundryup -i ${EXPECTED_FORGE_VER}"
  echo "   or put the pinned binary ahead of any other forge on PATH."
  echo "   A local forge that differs from CI means your green is not CI's green."
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "Toolchain pin gate FAILED."
  exit 1
fi
echo "✅ toolchain pinned: forge ${EXPECTED_FORGE_VER}, solc ${EXPECTED_SOLC}, evm ${EXPECTED_EVM}, isolate ${EXPECTED_ISOLATE}"
