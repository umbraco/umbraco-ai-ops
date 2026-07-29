#!/usr/bin/env bash
# Tests for the validate-repo-meta.sh WRAPPER in ops-install. Hermetic: bash + jq only.
#
# The wrapper exists because this skill's instructions name `scripts/validate-repo-meta.sh`
# while the real validator ships in the ops-capabilities plugin. From an installed ops-install
# that relative path resolved to nothing and an operator hand-checked the file instead. What is
# under test is therefore only the plumbing — that it finds the real one, passes arguments and
# exit codes straight through, and says something useful when it cannot find it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="$HERE/validate-repo-meta.sh"
[ -f "$W" ] || { echo "FATAL: wrapper not found"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

# --- the documented path exists at all ------------------------------------
# This is the whole point: the skill tells a human to run this, so it must be here.
check "the wrapper is where the skill says it is" 1 "$( [ -f "$W" ] && echo 1 || echo 0)"

# --- it delegates, and a valid file passes --------------------------------
good="$TMP/good"; mkdir -p "$good/.claude"
cat > "$good/.claude/ops-repo-meta.json" <<'JSON'
{ "version": 1, "lines": { "live": ["v17","v18"], "primary": "v18", "port_order": "downward" } }
JSON
bash "$W" "$good" >/dev/null 2>&1
check "a valid declared-facts file passes" 0 $?

# --- and an invalid one fails, so the exit code is really passed through ---
bad="$TMP/bad"; mkdir -p "$bad/.claude"
# `primary` not in `live` — the cross-field rule JSON Schema cannot express, which only the
# real validator knows about. If this fails, the wrapper is not reaching it.
cat > "$bad/.claude/ops-repo-meta.json" <<'JSON'
{ "version": 1, "lines": { "live": ["v17"], "primary": "v18", "port_order": "downward" } }
JSON
bash "$W" "$bad" >/dev/null 2>&1
check "primary outside live is rejected (so the real validator ran)" 1 $?

# --- a retired config key must still be refused ---------------------------
old="$TMP/old"; mkdir -p "$old/.claude"
printf '%s' '{ "version": 1, "ci": { "provider": "azure-pipelines" } }' > "$old/.claude/ops-repo-meta.json"
bash "$W" "$old" >/dev/null 2>&1
check "a retired config key is rejected" 1 $?

# --- no file at all is a pass: the framework defaults apply ----------------
none="$TMP/none"; mkdir -p "$none"
bash "$W" "$none" >/dev/null 2>&1
check "a repo with no file passes" 0 $?

# --- when ops-capabilities is absent, say so instead of failing opaquely ---
# ENGINE_ROOT points somewhere with a catalog but no ops-capabilities plugin.
fake="$TMP/fake"; mkdir -p "$fake/plugins/ops-install"; : > "$fake/catalog.json"
out="$(ENGINE_ROOT="$fake" bash "$W" "$good" 2>&1)"; rc=$?
check "a missing ops-capabilities exits 2" 2 $rc
check "  and names the plugin to install" 1 "$(printf '%s' "$out" | grep -c 'ops-capabilities@umbraco-ai-ops')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
