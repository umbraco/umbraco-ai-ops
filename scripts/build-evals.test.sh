#!/usr/bin/env bash
# Tests for build-evals.sh, plus the drift gate: the committed suites match catalog.json.
# Hermetic: bash + jq only, no network, no claude.
#
# If the drift case fails, run scripts/build-evals.sh and commit — never hand-edit a suite.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$HERE/build-evals.sh"
CATALOG="$HERE/../catalog.json"
EVALS="$HERE/../evals"
[ -f "$B" ] || { echo "FATAL: build-evals.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

# --- the drift gate -------------------------------------------------------
bash "$B" --check >/dev/null 2>&1
check "the committed suites match the catalog" 0 $?

# --- one suite per capability, and no orphans -----------------------------
check "one suite per catalogued capability" \
  "$(jq '.capabilities | length' "$CATALOG")" \
  "$(find "$EVALS" -name '*.eval.json' | wc -l | tr -d ' ')"

# --- every action is covered by the four contract cases -------------------
while IFS= read -r cap; do
  f="$EVALS/$cap.eval.json"
  # tr -d '\r' on BOTH sides: jq writes CRLF on some platforms, and while command substitution
  # drops a trailing CR it keeps the interior ones, so any MULTI-line comparison needs this.
  want="$(jq -r --arg c "$cap" '.capabilities[]|select(.capability==$c)|.operations[].action' "$CATALOG" | tr -d '\r' | sort)"
  for kind in example empty-context idempotency; do
    got="$(jq -r --arg k "$kind" '.cases[] | select(.id | endswith("/" + $k)) | .action' "$f" | tr -d '\r' | sort)"
    check "  $cap: every action has a $kind case" "$want" "$got"
  done
  check "  $cap: has an unknown-action case" "1" \
    "$(jq '[.cases[] | select(.id == "unknown-action")] | length' "$f")"
  check "  $cap: the idempotency case repeats" "2" \
    "$(jq -r '[.cases[] | select(.id | endswith("/idempotency")) | .repeat] | first' "$f")"
done < <(jq -r '.capabilities[].capability' "$CATALOG" | tr -d '\r')

# --- data capabilities get the structured-output case ---------------------
check "a data capability gets a structured-output case" "1" \
  "$(jq '[.cases[] | select(.id == "structured-output")] | length' "$EVALS/repo-meta.eval.json")"
check "a behavioural one does not" "0" \
  "$(jq '[.cases[] | select(.id == "structured-output")] | length' "$EVALS/integrate.eval.json")"

# --- the example context comes from the catalog, unaltered ---------------
check "the example context is the catalog's" \
  "$(jq -c '.capabilities[]|select(.capability=="integrate")|.operations[0].example' "$CATALOG")" \
  "$(jq -c '.cases[]|select(.id=="land/example")|.context' "$EVALS/integrate.eval.json")"
check "the empty-context case really is empty" "{}" \
  "$(jq -c '.cases[]|select(.id=="land/empty-context")|.context' "$EVALS/integrate.eval.json")"

# --- every case can actually be run --------------------------------------
check "every case has an action, a context and asserts" "0" \
  "$(jq -s '[.[].cases[] | select((.action|type) != "string" or (.context|type) != "object" or (.asserts|length) < 1)] | length' "$EVALS"/*.eval.json)"

# --- --check detects both directions of drift ----------------------------
cp -r "$EVALS" "$TMP/evals"
CATALOG_FILE="$CATALOG" EVALS_DIR="$TMP/evals" bash "$B" --check >/dev/null 2>&1
check "a clean copy passes --check" 0 $?

jq '.cases = []' "$TMP/evals/integrate.eval.json" > "$TMP/x" && mv "$TMP/x" "$TMP/evals/integrate.eval.json"
CATALOG_FILE="$CATALOG" EVALS_DIR="$TMP/evals" bash "$B" --check >/dev/null 2>&1
check "a hand-edited suite fails --check" 1 $?

rm -rf "$TMP/evals2"; cp -r "$EVALS" "$TMP/evals2"; rm "$TMP/evals2/notify.eval.json"
CATALOG_FILE="$CATALOG" EVALS_DIR="$TMP/evals2" bash "$B" --check >/dev/null 2>&1
check "a missing suite fails --check" 1 $?

rm -rf "$TMP/evals3"; cp -r "$EVALS" "$TMP/evals3"; cp "$EVALS/notify.eval.json" "$TMP/evals3/ghost.eval.json"
CATALOG_FILE="$CATALOG" EVALS_DIR="$TMP/evals3" bash "$B" --check >/dev/null 2>&1
check "a suite for a dropped capability fails --check" 1 $?

# --- regeneration is idempotent and self-healing -------------------------
EVALS_DIR="$TMP/evals" bash "$B" >/dev/null 2>&1
EVALS_DIR="$TMP/evals" bash "$B" --check >/dev/null 2>&1
check "regenerating repairs a hand-edited suite" 0 $?

# --- usage ---------------------------------------------------------------
bash "$B" --wat >/dev/null 2>&1; check "an unknown mode exits 2" 2 $?
CATALOG_FILE="$TMP/nope.json" bash "$B" >/dev/null 2>&1; check "a missing catalog exits 2" 2 $?

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
