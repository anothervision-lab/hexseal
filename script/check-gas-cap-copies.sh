#!/usr/bin/env bash
# Gate: every gas-cap literal restated in a test equals the constant that
# actually ships in src/Agreement.sol.
#
# WHY. The caps are `private constant` in Agreement, so a test cannot read
# them, and both gas-cap suites restate them by hand:
#
#     uint256 constant CAP_CLAIM_CLEAR = 200_000; // = Agreement.CLAIM_CLEAR_GAS
#
# That hand-copy is deliberate and must stay: reading the cap back out of the
# contract under test would make the assertion a mirror -- expected and
# measured coming from the same place, agreeing with themselves forever
# (docs/PROCESS.md). But until 1 Sept 2026 the copy was joined to the original
# by NOTHING except that `//` comment, and the comment is not checked by
# anything.
#
# The hole that leaves is the expensive one. When a headroom lock goes red the
# cheapest-looking repair is to raise the number in the test until it is green
# -- and the whole suite WOULD go green, while every EIP-1167 clone already on
# chain keeps enforcing the old cap in bytecode that cannot be changed for
# them, ever. The test would then be measuring a limit that exists nowhere.
# This gate is what makes that repair impossible to land quietly.
#
# It is the same class as check-appeal-window.sh, which holds the relayer's
# copies of APPEAL_REVIEW_WINDOW/FINALIZE_DELAY to the Solidity originals: two
# independently maintained copies of one number, each of which is meaningless
# if it drifts from the other. It is NOT a mirror -- a mirror derives the
# expectation from the thing under test at runtime and can never fail; this
# compares two human-maintained texts and fails the moment they disagree.
#
# Scope: only literals carrying an explicit `// = Agreement.NAME` annotation.
# A test that restates a cap WITHOUT that annotation is invisible here and is
# reported as such, rather than passing in silence.
#
# Usage:  ./script/check-gas-cap-copies.sh   (exit 0 pass, 1 mismatch, 3 cannot check)
set -euo pipefail

SRC="src/Agreement.sol"
if [[ ! -f "$SRC" ]]; then
  echo "❌ $SRC not found (cwd: $(pwd)) — run this gate from the repository root"
  exit 3
fi

norm() { echo "${1//_/}"; }   # 200_000 -> 200000

# --- the shipped constants -------------------------------------------------
# Anchored on the declaration so a mention inside a `//` comment cannot match.
declare -A SHIPPED=()
while IFS= read -r line; do
  name=$(echo "$line" | LC_ALL=C sed -nE 's/^[[:space:]]*uint256[[:space:]]+(private[[:space:]]+)?constant[[:space:]]+([A-Z0-9_]+)[[:space:]]*=.*/\2/p')
  val=$(echo  "$line" | LC_ALL=C sed -nE 's/^[[:space:]]*uint256[[:space:]]+(private[[:space:]]+)?constant[[:space:]]+[A-Z0-9_]+[[:space:]]*=[[:space:]]*([0-9_]+).*/\2/p')
  [[ -n "$name" && -n "$val" ]] && SHIPPED["$name"]=$(norm "$val")
done < <(LC_ALL=C command grep -aE '^[[:space:]]*uint256[[:space:]]+(private[[:space:]]+)?constant[[:space:]]+[A-Z0-9_]+[[:space:]]*=[[:space:]]*[0-9_]+' "$SRC")

if [[ ${#SHIPPED[@]} -eq 0 ]]; then
  echo "❌ parsed no uint256 constants out of $SRC — the gate would pass vacuously, which is the defect it exists to prevent"
  exit 3
fi

# --- the copies in the tests ----------------------------------------------
fail=0; checked=0
while IFS= read -r hit; do
  file="${hit%%:*}"; rest="${hit#*:}"; lineno="${rest%%:*}"; text="${rest#*:}"
  copy=$(echo "$text" | LC_ALL=C sed -nE 's/.*constant[[:space:]]+[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*([0-9_]+).*/\1/p')
  ref=$(echo  "$text" | LC_ALL=C sed -nE 's|.*//[[:space:]]*=[[:space:]]*Agreement\.([A-Z0-9_]+).*|\1|p')
  [[ -z "$copy" || -z "$ref" ]] && continue
  copy=$(norm "$copy")
  checked=$((checked+1))
  if [[ -z "${SHIPPED[$ref]+x}" ]]; then
    echo "❌ $file:$lineno refers to Agreement.$ref, which does not exist in $SRC"
    echo "   Either the constant was renamed and the test still names the old one,"
    echo "   or it was deleted and this copy now checks nothing."
    fail=1
    continue
  fi
  if [[ "$copy" != "${SHIPPED[$ref]}" ]]; then
    echo "❌ $file:$lineno has $copy, but $SRC has $ref = ${SHIPPED[$ref]}"
    echo "   These two must be the same number. If the test literal was raised to"
    echo "   make a headroom lock green: the clones already on chain enforce"
    echo "   ${SHIPPED[$ref]} in bytecode nobody can change for them, so the raised"
    echo "   test measures a limit that exists nowhere."
    fail=1
  fi
done < <(LC_ALL=C command grep -rn -- "constant.*=.*//.*=[[:space:]]*Agreement\." test/ 2>/dev/null || true)

if [[ "$checked" -eq 0 ]]; then
  echo "❌ no annotated cap copies found in test/ — nothing was compared."
  echo "   Zero checks is not a pass: it means the annotation format changed"
  echo "   and this gate went blind."
  exit 3
fi

if [[ "$fail" -ne 0 ]]; then
  echo; echo "Gas-cap copy gate FAILED."
  exit 1
fi
echo "✅ $checked cap copies in test/ all match their constants in $SRC"
