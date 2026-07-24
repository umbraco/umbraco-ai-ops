#!/usr/bin/env bash
# detect.sh — inspect a git repo and emit best-effort ai-ops config fields as JSON.
# Deterministic, read-only (never writes), no network. The umbraco-ops-setup skill runs
# this, shows the result, confirms/fills gaps with the user, then writes .claude/ai-ops.yml.
#
# Usage: bash detect.sh [repo-dir]   (default: current directory)
# Output: one JSON object on stdout; {"error": "..."} if the dir isn't a git repo.
set -uo pipefail

repo_dir="${1:-.}"
cd "$repo_dir" 2>/dev/null || { printf '{"error":"not a directory: %s"}\n' "$repo_dir"; exit 0; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf '{"error":"not a git repo"}\n'; exit 0; }

# --- source repo (owner/name) from origin ---------------------------------
origin="$(git remote get-url origin 2>/dev/null || true)"
source_repo="$(printf '%s' "$origin" \
  | sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#\.git$##; s#/$##')"

# --- branches -> branching model ------------------------------------------
branches="$(git branch -a --format='%(refname:short)' 2>/dev/null | sed 's#^origin/##' | sort -u)"
has() { printf '%s\n' "$branches" | grep -qx "$1"; }
top_major="$(printf '%s\n' "$branches" | grep -E '^v[0-9]+/dev$' | grep -oE '[0-9]+' | sort -n | tail -1)"

model="custom"; base=""; release_base=""
if [ -n "$top_major" ] && has "v${top_major}/main"; then
  model="versioned-gitflow"; base="v${top_major}/dev"; release_base="v${top_major}/main"
elif has dev && has main; then
  model="gitflow"; base="dev"; release_base="main"
elif has main && ! has dev; then
  model="main-only"; base="main"; release_base="main"
fi
default_branch="$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's#^origin/##')"

# --- CI provider ----------------------------------------------------------
ci="unknown"
if [ -n "$(git ls-files 'azure-pipelines*.yml' '.azure-pipelines/*' 2>/dev/null | head -1)" ]; then
  ci="azure-pipelines"
elif [ -n "$(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' 2>/dev/null | head -1)" ]; then
  ci="github-checks"
fi

# --- release hints --------------------------------------------------------
nbgv=false; [ -n "$(git ls-files 'version.json' 2>/dev/null | head -1)" ] && nbgv=true
has_release_tags=false; [ -n "$(git tag --list 'release-*' 2>/dev/null | head -1)" ] && has_release_tags=true
release_skill=""
[ -d .claude/skills/release-management ] && release_skill="release-management"

# --- stack (for the build-playbook scaffold) ------------------------------
stack="unknown"
if [ -n "$(git ls-files '*.slnx' '*.sln' '*.csproj' 2>/dev/null | head -1)" ]; then stack="dotnet"
elif [ -n "$(git ls-files 'package.json' 2>/dev/null | head -1)" ]; then stack="node"; fi

# --- emit -----------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg source "$source_repo" --arg model "$model" --arg base "$base" \
    --arg rbase "$release_base" --arg def "$default_branch" --arg ci "$ci" \
    --argjson nbgv "$nbgv" --argjson rtags "$has_release_tags" \
    --arg rskill "$release_skill" --arg stack "$stack" '
    { source: $source,
      branching: { model: $model, base: $base, release_base: $rbase, default_branch: $def },
      ci: { provider: $ci },
      release: { nbgv: $nbgv, has_release_tags: $rtags, release_skill: $rskill },
      stack: $stack }'
else
  printf '{"source":"%s","branching":{"model":"%s","base":"%s","release_base":"%s","default_branch":"%s"},"ci":{"provider":"%s"},"stack":"%s"}\n' \
    "$source_repo" "$model" "$base" "$release_base" "$default_branch" "$ci" "$stack"
fi
