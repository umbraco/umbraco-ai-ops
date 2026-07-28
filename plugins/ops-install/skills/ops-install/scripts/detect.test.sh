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

# --- nbgv: version.json at ANY depth, not just the root -------------------
# A multi-product repo versions each product separately, so a root-only pathspec reported
# false for a repo that plainly uses Nerdbank.GitVersioning. Reported from a real install.
d="$(mkrepo)"; check "no version.json means no nbgv" false "$(field "$d" '.release.nbgv')"; rm -rf "$d"

d="$(mkrepo)"; : > "$d/version.json"
git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -q -m v
check "a root version.json is nbgv" true "$(field "$d" '.release.nbgv')"; rm -rf "$d"

d="$(mkrepo)"; mkdir -p "$d/Product.One"; : > "$d/Product.One/version.json"
git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -q -m v
check "a NESTED version.json is nbgv too" true "$(field "$d" '.release.nbgv')"; rm -rf "$d"

d="$(mkrepo)"; printf '<Project><PackageVersion Include="Nerdbank.GitVersioning" /></Project>' \
  > "$d/Directory.Packages.props"
git -C "$d" add -A && git -C "$d" -c user.email=t@t -c user.name=t commit -q -m v
check "a package reference alone is nbgv" true "$(field "$d" '.release.nbgv')"; rm -rf "$d"

# --- release tags: any tag, not a `release-*` naming guess ----------------
d="$(mkrepo)"; check "no tags means no release tags" false "$(field "$d" '.release.has_release_tags')"; rm -rf "$d"

d="$(mkrepo)"; git -C "$d" tag 2026.07.1
check "a date-style tag counts" true "$(field "$d" '.release.has_release_tags')"; rm -rf "$d"

d="$(mkrepo)"; git -C "$d" tag 'Product.One@1.2.3'
check "a product-scoped tag counts" true "$(field "$d" '.release.has_release_tags')"; rm -rf "$d"

# --- lines_seen: the candidate list the installer's question is seeded from
d="$(mkrepo)"; check "no version lines means an empty list" 0 "$(field "$d" '.branching.lines_seen | length')"; rm -rf "$d"

d="$(mkrepo)"
for b in v17/dev v17/main v18/dev v18/main v13/main; do git -C "$d" branch "$b"; done
check "every vN line is listed once" 3 "$(field "$d" '.branching.lines_seen | length')"
check "  newest first"           v18 "$(field "$d" '.branching.lines_seen[0]')"
check "  and the oldest last"    v13 "$(field "$d" '.branching.lines_seen[-1]')"
check "  a main-only line is still a line" 1 \
  "$(field "$d" '[.branching.lines_seen[] | select(. == "v13")] | length')"
rm -rf "$d"

# not a git repo
check "non-repo error" "not a git repo" "$(bash "$DETECT" "$(mktemp -d)" | jq -r '.error')"

echo "----"
echo "detect tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
