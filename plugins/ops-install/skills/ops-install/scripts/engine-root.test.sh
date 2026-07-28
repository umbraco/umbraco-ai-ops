#!/usr/bin/env bash
# Tests for engine-root.sh. Hermetic: bash only, nothing created outside a temp dir.
#
# The property under test is that the engine root resolves in BOTH shipped layouts — the git
# checkout (an extra `plugins/` level) and an installed plugin (none) — because assuming one
# fixed depth is the bug this helper exists to fix.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$HERE/engine-root.sh"
[ -f "$H" ] || { echo "FATAL: engine-root.sh not found"; exit 2; }
# shellcheck source=/dev/null
. "$H"

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

# --- the git-checkout layout ----------------------------------------------
co="$TMP/checkout"
mkdir -p "$co/plugins/ops-install/skills/ops-install/scripts"
: > "$co/catalog.json"
check "checkout layout resolves to the repo root" "$co" \
  "$(ops_engine_root "$co/plugins/ops-install/skills/ops-install/scripts")"

# --- the installed-plugin layout (one level shallower) --------------------
mk="$TMP/marketplaces/umbraco-ai-ops"
mkdir -p "$mk/ops-install/skills/ops-install/scripts"
: > "$mk/catalog.json"
check "installed layout resolves to the marketplace dir" "$mk" \
  "$(ops_engine_root "$mk/ops-install/skills/ops-install/scripts")"

# --- the same fixed depth would have been wrong for one of them -----------
check "the two layouts really do differ in depth" "different" \
  "$([ "$(cd "$co/plugins/ops-install/skills/ops-install/scripts/../../../../.." && pwd)" \
      = "$(cd "$mk/ops-install/skills/ops-install/scripts/../../../../.." 2>/dev/null && pwd)" ] \
    && echo same || echo different)"

# --- ENGINE_ROOT wins over the walk ---------------------------------------
check "ENGINE_ROOT overrides detection" "/somewhere/else" \
  "$(ENGINE_ROOT=/somewhere/else ops_engine_root "$co/plugins/ops-install/skills/ops-install/scripts")"

# --- no catalog anywhere: falls back, never prints nothing ----------------
bare="$TMP/bare/a/b/c/d/e"; mkdir -p "$bare"
out="$(ops_engine_root "$bare")"
check "a tree with no catalog still returns a path" "yes" "$([ -n "$out" ] && echo yes || echo no)"

# --- the walk itself ------------------------------------------------------
ops_find_engine "$bare" >/dev/null 2>&1; check "find_engine fails when there is no catalog" 1 $?
check "find_engine finds one directly above" "$co" \
  "$(ops_find_engine "$co/plugins")"
check "  and one in the same directory" "$co" "$(ops_find_engine "$co")"

# --- a consumer repo must not be mistaken for the engine ------------------
# Nothing but the engine ships a catalog.json, which is what makes the walk safe.
consumer="$TMP/consumer/.claude/skills/ops-change"; mkdir -p "$consumer"
ops_find_engine "$consumer" >/dev/null 2>&1
check "a consumer repo is not mistaken for the engine" 1 $?

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
