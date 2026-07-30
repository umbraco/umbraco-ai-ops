#!/usr/bin/env bash
# Tests for catalog-to-readme.sh, plus the drift gate: the committed README's
# action table MUST match catalog.json. Hermetic: bash + jq only, no network.
#
# If the drift case fails, the fix is to run scripts/catalog-to-readme.sh and
# commit the result — never to hand-edit the generated block.
#
# Usage: bash catalog-to-readme.test.sh   (exits non-zero if any case fails)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/catalog-to-readme.sh"
CATALOG="$HERE/../catalog.json"
README="$HERE/../README.md"
[ -f "$GEN" ] || { echo "FATAL: catalog-to-readme.sh not found at $GEN"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi
}
status() { # status <name> <want-exit> <cmd...>
  local name="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  check "$name" "$want" "$got"
}

# --- the drift gate --------------------------------------------------------
status "the committed README matches catalog.json" 0 bash "$GEN" --check

# --- --print --------------------------------------------------------------
want_rows="$(jq '[.capabilities[].operations | length] | add' "$CATALOG")"
got_rows="$(bash "$GEN" --print | grep -c '^<tr>')"
check "one row per catalogued action" "$want_rows" "$got_rows"
check "the table opens with a <table>" "<table>" "$(bash "$GEN" --print | head -1)"
check "the table has a header" \
  "<thead><tr><th>Capability</th><th>Action</th><th>What it does</th></tr></thead>" \
  "$(bash "$GEN" --print | sed -n 2p)"
# A blank line inside a raw HTML block ends it, so the table would render as text.
check "no blank line inside the block" "0" "$(bash "$GEN" --print | grep -c '^$')"

# --- first sentence, HTML escaping, backticks, rowspan ---------------------
cat > "$TMP/one.json" <<'JSON'
{
  "version": 1,
  "reserved_skill_names": ["ops-issue-loop"],
  "capabilities": [
    {
      "capability": "demo",
      "kind": "behavioral",
      "visibility": "service",
      "framework_default": false,
      "description": "A demo.",
      "operations": [
        { "action": "go", "description": "First sentence. Second sentence MUST be dropped.", "example": {} },
        { "action": "markup", "description": "Takes a<b & `code` as input.", "example": {} }
      ]
    },
    {
      "capability": "solo",
      "kind": "behavioral",
      "visibility": "service",
      "framework_default": false,
      "description": "One action only.",
      "operations": [
        { "action": "only", "description": "The single action.", "example": {} }
      ]
    }
  ]
}
JSON
out="$(CATALOG_FILE="$TMP/one.json" bash "$GEN" --print)"
check "the first action of a capability carries the rowspan" \
  '<tr><td rowspan="2"><code>ops-demo</code></td><td><code>go</code></td><td>First sentence.</td></tr>' \
  "$(printf '%s' "$out" | grep '>go<')"
check "a later action omits the capability cell" \
  '<tr><td><code>markup</code></td><td>Takes a&lt;b &amp; <code>code</code> as input.</td></tr>' \
  "$(printf '%s' "$out" | grep '>markup<')"
check "a one-action capability gets no rowspan" \
  '<tr><td><code>ops-solo</code></td><td><code>only</code></td><td>The single action.</td></tr>' \
  "$(printf '%s' "$out" | grep '>only<')"

# --- marker handling ------------------------------------------------------
printf '# no markers here\n' > "$TMP/bare.md"
status "rejects a README with no markers" 2 env README_FILE="$TMP/bare.md" bash "$GEN" --check

printf '# t\n<!-- BEGIN GENERATED: catalog-actions -->\n' > "$TMP/half.md"
status "rejects a README missing the END marker" 2 env README_FILE="$TMP/half.md" bash "$GEN" --check

status "rejects a missing catalog" 2 env CATALOG_FILE="$TMP/nope.json" bash "$GEN" --check
status "rejects an unknown mode" 2 bash "$GEN" --wat

# --- write, then check ----------------------------------------------------
cat > "$TMP/stale.md" <<'MD'
# title

before

<!-- BEGIN GENERATED: catalog-actions (scripts/catalog-to-readme.sh) -->
| Capability | Action | What it does |
|---|---|---|
| `ops-stale` | `gone` | This action no longer exists. |
<!-- END GENERATED: catalog-actions -->

after
MD
status "--check fails on a stale block" 1 env README_FILE="$TMP/stale.md" CATALOG_FILE="$TMP/one.json" bash "$GEN" --check
status "write mode rewrites the block"  0 env README_FILE="$TMP/stale.md" CATALOG_FILE="$TMP/one.json" bash "$GEN"
status "--check passes after a write"   0 env README_FILE="$TMP/stale.md" CATALOG_FILE="$TMP/one.json" bash "$GEN" --check

check "the stale row is gone"        "0" "$(grep -c 'ops-stale' "$TMP/stale.md")"
check "text before the block survives" "1" "$(grep -c '^before$' "$TMP/stale.md")"
check "text after the block survives"  "1" "$(grep -c '^after$'  "$TMP/stale.md")"
check "the markers survive"            "2" "$(grep -c 'GENERATED: catalog-actions' "$TMP/stale.md")"

# Writing twice must not change anything the second time.
cp "$TMP/stale.md" "$TMP/once.md"
README_FILE="$TMP/stale.md" CATALOG_FILE="$TMP/one.json" bash "$GEN" >/dev/null 2>&1
if cmp -s "$TMP/once.md" "$TMP/stale.md"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: writing twice is not idempotent"; fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
