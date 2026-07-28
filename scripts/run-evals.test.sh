#!/usr/bin/env bash
# Tests for run-evals.sh — the hermetic paths only. Running evals for real needs `claude` and
# a repo, so these exercise --list and --plan and check that the real path refuses cleanly
# rather than half-running.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/run-evals.sh"
EVALS="$HERE/../evals"
[ -f "$R" ] || { echo "FATAL: run-evals.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }
has()   { if printf '%s' "$2" | grep -qF "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — [$3] not in output"; fi; }

# --- --list ---------------------------------------------------------------
out="$(bash "$R" --list 2>&1)"; check "--list exits 0" 0 $?
has "--list names every skill"        "$out" "ops-integrate"
has "--list names a data capability"  "$out" "ops-repo-meta"
has "--list names cases"              "$out" "land/example"
has "--list flags the always-repo ones" "$out" "always the repo's"
has "--list flags the inherited ones"   "$out" "has a default"
check "--list lists every case in the suites" \
  "$(jq -s '[.[].cases|length]|add' "$EVALS"/*.eval.json)" \
  "$(bash "$R" --list 2>/dev/null | grep -cE '^    ')"

# --- --plan ---------------------------------------------------------------
out="$(bash "$R" --plan integrate 2>&1)"; check "--plan exits 0" 0 $?
has "--plan shows the invocation"  "$out" "Invoke the skill named \`ops-integrate\` with action \`land\`"
has "--plan passes the context"    "$out" '{"pr":{"repo":"owner/repo","number":8890}}'
has "--plan shows the judge prompt" "$out" "VERDICT: PASS"
has "--plan carries the asserts"   "$out" "NO second side effect"
has "--plan says the repeat count" "$out" "Do it 2 times in a row"
has "--plan tells the judge to be strict" "$out" "Be strict"
has "--plan forbids repairing"     "$out" "not a repair"
check "--plan runs nothing"        "1" "$(printf '%s' "$out" | grep -c 'none run')"

# --- the real path refuses cleanly ---------------------------------------
bash "$R" integrate >/dev/null 2>&1;            check "no repo root exits 2" 2 $?
bash "$R" integrate "$TMP/nope" >/dev/null 2>&1; check "a missing repo exits 2" 2 $?
bash "$R" >/dev/null 2>&1;                       check "no arguments exits 2" 2 $?
bash "$R" not-a-capability "$TMP" >/dev/null 2>&1; check "an unknown capability exits 2" 2 $?
EVALS_DIR="$TMP/none" bash "$R" --list >/dev/null 2>&1; check "a missing evals dir exits 2" 2 $?

# The real path must refuse without `claude`, and say why. Stripping PATH to prove it is not
# portable — jq and coreutils live in different places per platform — so assert the guard is
# present, and only assert the exit code where claude genuinely is absent.
if grep -q 'command -v claude' "$R" && grep -q 'not part of CI' "$R"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: run-evals must guard on claude and say it is opt-in"; fi
mkdir -p "$TMP/repo"
if ! command -v claude >/dev/null 2>&1; then
  out="$(bash "$R" integrate "$TMP/repo" 2>&1)"; rc=$?
  check "without claude it exits 2" 2 "$rc"
  has "  and says it is opt-in" "$out" "not part of CI"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
