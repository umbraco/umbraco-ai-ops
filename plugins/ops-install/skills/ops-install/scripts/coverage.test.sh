#!/usr/bin/env bash
# Tests for coverage.sh. Hermetic: bash + jq only, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COV="$HERE/coverage.sh"
[ -f "$COV" ] || { echo "FATAL: coverage.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

# A tiny engine: two capabilities, one of which has a framework default on disk.
ENG="$TMP/engine"; mkdir -p "$ENG/plugins/p/skills/ops-ci"
printf -- "---\nname: ops-ci\n---\n" > "$ENG/plugins/p/skills/ops-ci/SKILL.md"
cat > "$ENG/catalog.json" <<'JSON'
{
  "version": 1,
  "reserved_skill_names": ["ops-issue-loop"],
  "capabilities": [
    { "capability": "change", "kind": "behavioral", "visibility": "service", "framework_default": false,
      "description": "d", "operations": [{ "action": "implement", "description": "d", "example": {} }] },
    { "capability": "ci", "kind": "behavioral", "visibility": "cross-cutting", "framework_default": true,
      "description": "d", "operations": [{ "action": "status", "description": "d", "example": {} }] }
  ]
}
JSON
run() { env ENGINE_ROOT="$ENG" CATALOG_FILE="$ENG/catalog.json" bash "$COV" "$@" 2>/dev/null; }

# --- nothing shipped: one inherited, one missing ---------------------------
REPO="$TMP/bare"; mkdir -p "$REPO"
out="$(run "$REPO" --json)"; rc=$?
check "a repo missing a repo-only capability exits 1" 1 "$rc"
check "  ops-ci is inherited"  "inherited" "$(printf '%s' "$out" | jq -r '.capabilities[]|select(.skill=="ops-ci")|.state')"
check "  ops-change is missing" "missing"  "$(printf '%s' "$out" | jq -r '.capabilities[]|select(.skill=="ops-change")|.state')"
check "  summary counts"        "0 1 1"    "$(printf '%s' "$out" | jq -r '.summary|"\(.present) \(.inherited) \(.missing)"')"

# --- the repo ships the missing one ---------------------------------------
REPO2="$TMP/full"; mkdir -p "$REPO2/.claude/skills/ops-change"
printf -- "---\nname: ops-change\n---\n" > "$REPO2/.claude/skills/ops-change/SKILL.md"
out="$(run "$REPO2" --json)"; rc=$?
check "full coverage exits 0" 0 "$rc"
check "  ops-change is present" "present" "$(printf '%s' "$out" | jq -r '.capabilities[]|select(.skill=="ops-change")|.state')"

# --- a repo override beats the engine default ------------------------------
mkdir -p "$REPO2/.claude/skills/ops-ci"; printf -- "---\nname: ops-ci\n---\n" > "$REPO2/.claude/skills/ops-ci/SKILL.md"
out="$(run "$REPO2" --json)"
check "an override is reported present, not inherited" "present" \
  "$(printf '%s' "$out" | jq -r '.capabilities[]|select(.skill=="ops-ci")|.state')"

# --- a skill directory with no SKILL.md does not count ---------------------
REPO3="$TMP/hollow"; mkdir -p "$REPO3/.claude/skills/ops-change"
check "an empty skill dir is not coverage" "missing" \
  "$(run "$REPO3" --json | jq -r '.capabilities[]|select(.skill=="ops-change")|.state')"

# --- every catalogued capability is reported ------------------------------
check "one row per catalogued capability" 2 "$(run "$REPO" --json | jq '.capabilities | length')"

# --- text mode + argument handling ----------------------------------------
run "$REPO" >/dev/null 2>&1; check "text mode also exits 1 when missing" 1 $?
check "text mode names the missing skill" 1 "$(run "$REPO" 2>/dev/null | grep -c 'ops-change *missing')"
bash "$COV" >/dev/null 2>&1; check "no argument exits 2" 2 $?
bash "$COV" "$TMP/nope" >/dev/null 2>&1; check "a missing directory exits 2" 2 $?
env ENGINE_ROOT="$ENG" CATALOG_FILE="$TMP/nope.json" bash "$COV" "$REPO" >/dev/null 2>&1
check "a missing catalog exits 2" 2 $?

# --- the real engine reports on itself ------------------------------------
bash "$COV" "$HERE/../../../../.." >/dev/null 2>&1
check "the engine repo itself is missing the two repo-only capabilities" 1 $?

# --- a mistyped option must not silently become the text report ------------
optrepo="$TMP/optcheck"; mkdir -p "$optrepo"
env ENGINE_ROOT="$ENG" CATALOG_FILE="$ENG/catalog.json" bash "$COV" "$optrepo" --jsonn >/dev/null 2>&1
check "an unknown option exits 2" 2 $?

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
