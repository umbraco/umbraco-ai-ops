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

# --- the installed-plugin layout ------------------------------------------
# The real shape, verified against a live install: the plugin cache holds ONLY that plugin's
# skills — no catalog.json anywhere above it — while the full checkout sits sideways in
# marketplaces/. Walking up alone finds nothing here, which is why the first fix failed.
home="$TMP/home/.claude/plugins"
cache="$home/cache/umbraco-ai-ops/ops-install/0.2.0/skills/ops-install/scripts"
mkt="$home/marketplaces/umbraco-ai-ops"
mkdir -p "$cache" "$mkt/plugins/ops-install"
: > "$mkt/catalog.json"
check "installed layout finds the marketplace clone" "$mkt" "$(ops_engine_root "$cache")"

check "  walking up alone would have found nothing" "nothing" \
  "$(d="$cache" p=""; r=nothing; while [ -n "$d" ] && [ "$d" != "$p" ]; do \
       [ -f "$d/catalog.json" ] && { r=found; break; }; p="$d"; d="$(dirname "$d")"; done; echo "$r")"

# A marketplace without plugins/ is some other marketplace, not this engine.
other="$TMP/other/.claude/plugins"
mkdir -p "$other/cache/x/p/1/skills/s/scripts" "$other/marketplaces/unrelated"
: > "$other/marketplaces/unrelated/catalog.json"
ops_find_engine "$other/cache/x/p/1/skills/s/scripts" >/dev/null 2>&1
check "a marketplace with no plugins/ is not the engine" 1 $?

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
