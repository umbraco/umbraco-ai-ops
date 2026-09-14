#!/usr/bin/env bash
# Tests for validate-repo-skills.sh. Hermetic: bash + jq only, no network.
#
# The rules themselves are tested next to the script that owns them
# (scripts/validate-capability-skills.test.sh). What is tested HERE is the wrapper's own job:
# it finds the engine, it passes the repo through, and when it cannot find the engine it says
# BLOCKED instead of passing. That last one is the case that matters — a gate that cannot run
# must never read as a gate that ran.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="$HERE/validate-repo-skills.sh"
[ -f "$W" ] || { echo "FATAL: validate-repo-skills.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi
}
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

# A consumer repo owning one clean capability skill.
mkconsumer() { # mkconsumer <name> -> prints root
  local r="$TMP/$1"; mkdir -p "$r/.claude/skills/ops-change"
  cat > "$r/.claude/skills/ops-change/SKILL.md" <<'EOF'
---
name: ops-change
description: >-
  Build one change in this repo. Called by name with (action, context-json). NOT for direct use
  — never select it from a description match.
---
# ops-change
EOF
  printf '%s' "$r"
}

good="$(mkconsumer good)"
check "a clean consumer repo passes" "0" "$(rc_of bash "$W" "$good")"

flagged="$(mkconsumer flagged)"
sed -i 's/^name: ops-change$/name: ops-change\ndisable-model-invocation: true/' \
  "$flagged/.claude/skills/ops-change/SKILL.md"
check "a flagged consumer skill fails" "1" "$(rc_of bash "$W" "$flagged")"

out="$(bash "$W" "$flagged" 2>&1)"
if printf '%s' "$out" | grep -q "no loop can call it"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: the wrapper should pass the validator's reason through"; fi

# --- argument handling -----------------------------------------------------
check "no argument is a usage error"      "2" "$(rc_of bash "$W")"
check "a missing directory is an error"   "2" "$(rc_of bash "$W" "$TMP/nope")"

# --- the case that must never read as a pass -------------------------------
# ENGINE_ROOT pointed somewhere with no validator. Exit 2 (blocked), never 0.
empty="$TMP/no-engine"; mkdir -p "$empty"
check "an unreachable engine is BLOCKED, not a pass" \
  "2" "$(rc_of env ENGINE_ROOT="$empty" bash "$W" "$good")"

out="$(ENGINE_ROOT="$empty" bash "$W" "$good" 2>&1)"
if printf '%s' "$out" | grep -q "BLOCKED"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: an unreachable engine should say BLOCKED"; fi
if printf '%s' "$out" | grep -qi "not a pass"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: the blocked message should say it is not a pass"; fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
