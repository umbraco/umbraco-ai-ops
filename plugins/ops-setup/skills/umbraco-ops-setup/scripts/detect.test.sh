#!/usr/bin/env bash
# Tests for detect.sh — creates throwaway local git repos and asserts detection.
# Hermetic: bash + git + jq only, no network. Temp repos are removed after each case.
#
# Usage: bash detect.test.sh   (exits non-zero if any case fails)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$HERE/detect.sh"
[ -f "$DETECT" ] || { echo "FATAL: detect.sh not found at $DETECT"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi
}
mkrepo() { # mkrepo -> prints a fresh repo dir on branch main with one commit
  local d; d="$(mktemp -d)"
  git -C "$d" init -q -b main 2>/dev/null || { git -C "$d" init -q; git -C "$d" symbolic-ref HEAD refs/heads/main; }
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s' "$d"
}
field() { bash "$DETECT" "$1" | jq -r "$2"; }

# gitflow: dev + main
d="$(mkrepo)"; git -C "$d" branch dev
check "gitflow model" gitflow "$(field "$d" '.branching.model')"
check "gitflow base"  dev     "$(field "$d" '.branching.base')"
rm -rf "$d"

# versioned-gitflow: v18/dev + v18/main (+ main)
d="$(mkrepo)"; git -C "$d" branch v18/dev; git -C "$d" branch v18/main
check "versioned model"        versioned-gitflow "$(field "$d" '.branching.model')"
check "versioned base"         v18/dev           "$(field "$d" '.branching.base')"
check "versioned release_base" v18/main          "$(field "$d" '.branching.release_base')"
rm -rf "$d"

# picks the HIGHEST major
d="$(mkrepo)"; for m in 15 17 18; do git -C "$d" branch "v$m/dev"; git -C "$d" branch "v$m/main"; done
check "versioned top major" v18/dev "$(field "$d" '.branching.base')"
rm -rf "$d"

# main-only
d="$(mkrepo)"
check "main-only model" main-only "$(field "$d" '.branching.model')"
rm -rf "$d"

# CI: azure-pipelines detected from a tracked azure-pipelines.yml
d="$(mkrepo)"; echo "trigger: none" > "$d/azure-pipelines.yml"; git -C "$d" -c user.email=t@t -c user.name=t add -A; git -C "$d" -c user.email=t@t -c user.name=t commit -q -m ci
check "ci azure" azure-pipelines "$(field "$d" '.ci.provider')"
rm -rf "$d"

# not a git repo
check "non-repo error" "not a git repo" "$(bash "$DETECT" "$(mktemp -d)" | jq -r '.error')"

echo "----"
echo "detect tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
