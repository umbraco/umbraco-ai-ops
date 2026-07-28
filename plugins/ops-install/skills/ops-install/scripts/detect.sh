#!/usr/bin/env bash
# detect.sh — inspect a git repo and emit best-effort repo facts as JSON.
# Deterministic, read-only (never writes), no network. `ops-install` runs this, shows the
# result, and confirms or fills the gaps with a human; `ops-repo-meta` uses it as the seed for
# `identity` and `lines`. It writes no config file — there isn't one any more.
#
# It is a SEED, not an authority. Anything a human had to decide — the primary line, the port
# direction, which repo holds issues — is not detectable, and a repo declares it by shipping
# its own `ops-repo-meta`.
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
  | sed -E 's#^(git@github\.com:|https://github\.com/|ssh://git@github\.com/)##; s#/+$##; s#\.git$##')"

# --- branches -> branching model ------------------------------------------
branches="$(git branch -a --format='%(refname:short)' 2>/dev/null | sed 's#^origin/##' | sort -u)"
has() { printf '%s\n' "$branches" | grep -qx "$1"; }
top_major="$(printf '%s\n' "$branches" | grep -E '^v[0-9]+/dev$' | grep -oE '[0-9]+' | sort -n | tail -1)"

# Every `vN` line that has a branch, newest first. A SEED for the installer's question about
# which lines are live — a line can exist and be finished, so this is the candidate list to
# offer a human, never the answer. Empty for a repo with no version lines.
lines_seen="$(printf '%s\n' "$branches" \
  | sed -n 's#^\(v[0-9]\+\)/\(dev\|main\)$#\1#p' \
  | sort -u -t v -k2 -n -r)"

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
# Nerdbank.GitVersioning: a `version.json` ANYWHERE, not just the root — a multi-product
# repo versions each product separately (`Umbraco.Automate/version.json`), so a root-only
# pathspec reported false for a repo that plainly uses it. The package reference in the
# build props is the second signal, and either alone is enough.
nbgv=false
[ -n "$(git ls-files '*version.json' 2>/dev/null | head -1)" ] && nbgv=true
if [ "$nbgv" = false ]; then
  for f in Directory.Packages.props Directory.Build.props Directory.Build.targets; do
    [ -f "$f" ] && grep -q 'Nerdbank\.GitVersioning' "$f" 2>/dev/null && { nbgv=true; break; }
  done
fi

# Release tags: ANY tag, not a `release-*` naming guess. Real repos tag `2026.07.1` or
# `Umbraco.Automate@1.2.3`; the old pattern matched neither and reported false for a repo
# with 28 tags. The honest question is "does this repo tag at all", and any tag answers it.
has_release_tags=false; [ -n "$(git tag --list 2>/dev/null | head -1)" ] && has_release_tags=true
release_skill=""
[ -d .claude/skills/release-management ] && release_skill="release-management"

# --- stack (informs the ops-change scaffold) -------------------------------
stack="unknown"
if [ -n "$(git ls-files '*.slnx' '*.sln' '*.csproj' 2>/dev/null | head -1)" ]; then stack="dotnet"
elif [ -n "$(git ls-files 'package.json' 2>/dev/null | head -1)" ]; then stack="node"; fi

# --- override signals ------------------------------------------------------
# Hints that an INHERITED framework default probably does not fit this repo. Coverage matches
# skill names, so it cannot tell a suitable default from an unsuitable one; these give the
# installer something concrete to ask about instead of a generic "are you sure?".
#
# Every one is a hint, never a conclusion. A repo with a docker-compose.yml may still be fine
# on the bare-worktree default — the point is that a human is asked, having been shown why.
sig_workspace=false
[ -n "$(git ls-files 'docker-compose*' 'Dockerfile' '*.docker-compose.yml' 2>/dev/null | head -1)" ] && sig_workspace=true
[ "$sig_workspace" = false ] && [ -n "$(git ls-files 2>/dev/null | grep -Ei '(demo|test)-?site|install-.*site|seed.*\.(sql|ps1|sh)' | head -1)" ] && sig_workspace=true
[ "$sig_workspace" = false ] && [ -d .claude/worktrees ] && sig_workspace=true

sig_feed=false
[ -n "$(git ls-files 'NuGet.config' 'NuGet.Config' 'nuget.config' '.npmrc' 2>/dev/null | head -1)" ] && sig_feed=true

sig_notify=false
[ -n "$(git ls-files '.claude/skills/*' 2>/dev/null | grep -Ei 'slack|teams' | head -1)" ] && sig_notify=true

# More than one live line means branching is doing real work — cutover, per-line strategy — and
# is the case where the default is most likely to be too simple.
sig_branching=false
[ "$(printf '%s\n' "$lines_seen" | grep -c '^v[0-9]')" -gt 1 ] && sig_branching=true

# --- emit -----------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg source "$source_repo" --arg model "$model" --arg base "$base" \
    --arg rbase "$release_base" --arg def "$default_branch" --arg ci "$ci" \
    --argjson nbgv "$nbgv" --argjson rtags "$has_release_tags" \
    --argjson lines "$(printf '%s\n' "$lines_seen" | grep -v '^$' | jq -R . | jq -s -c .)" \
    --argjson sws "$sig_workspace" --argjson sfd "$sig_feed" \
    --argjson snt "$sig_notify" --argjson sbr "$sig_branching" \
    --arg rskill "$release_skill" --arg stack "$stack" '
    { source: $source,
      branching: { model: $model, base: $base, release_base: $rbase, default_branch: $def,
                   lines_seen: $lines },
      ci: { provider: $ci },
      release: { nbgv: $nbgv, has_release_tags: $rtags, release_skill: $rskill },
      stack: $stack,
      override_signals: { workspace: $sws, private_feed: $sfd,
                          notify: $snt, branching: $sbr } }'
else
  printf '{"source":"%s","branching":{"model":"%s","base":"%s","release_base":"%s","default_branch":"%s"},"ci":{"provider":"%s"},"stack":"%s"}\n' \
    "$source_repo" "$model" "$base" "$release_base" "$default_branch" "$ci" "$stack"
fi
