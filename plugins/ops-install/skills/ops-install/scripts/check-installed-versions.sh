#!/usr/bin/env bash
# check-installed-versions.sh — is your installed copy of the engine current?
#
# WHY THIS IS A REPORT AND NOT AN AUTO-UPDATER. Installing a plugin is Claude Code's job: it
# extracts into a version-keyed cache directory AND records the install in
# installed_plugins.json. A script that wrote those itself would be reverse-engineering another
# tool's private state, and would break silently the first time that layout changed. So this
# detects and prints the exact commands. You run them.
#
# It exists because the failure it catches is invisible. A plugin cache is keyed by version:
#
#   ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
#
# so an out-of-date install keeps serving the old copy with no error, no warning, and behaviour
# that does not match the code you are reading. That has already cost real debugging time —
# twice in one day — which is the whole reason this exists.
#
# BEHIND AND NOT-INSTALLED ARE DIFFERENT ANSWERS, and only one of them is a problem.
#
#   behind         you have this plugin, at an older version than the marketplace offers. That is
#                  the invisible failure above: stale behaviour, no error. Exit 1.
#   not installed  you do not have it. Often deliberate: onboarding needs only ops-install,
#                  ops-capabilities and github-ops, and the loops are installed later. Exit 0,
#                  and list them so the operator can install what they are about to need.
#
# Conflating the two made this script exit 1 on every fresh onboarding, at a step whose
# instruction is "stop if it says you are behind". The documented install path could not get
# past its own first check.
#
# Usage:
#   check-installed-versions.sh            # report, exit 1 only if something is BEHIND
#   check-installed-versions.sh --quiet    # print only when something needs attention
#
# Env: MARKETPLACE_FILE, OPS_CACHE_DIR, MARKETPLACE_NAME override the resolved defaults.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the manifest the same way every other script here resolves the catalog: walk up for
# the engine root, and sideways into the marketplace clone when running from a plugin cache.
# The manifest has to come from the MARKETPLACE, not from a checkout — a consumer has no engine
# checkout, and the whole question this script answers is "what does the marketplace offer that
# I have not installed?".
. "$here/engine-root.sh"
manifest="${MARKETPLACE_FILE:-$(ops_engine_root "$here")/.claude-plugin/marketplace.json}"
name="${MARKETPLACE_NAME:-umbraco-ai-ops}"
cache="${OPS_CACHE_DIR:-$HOME/.claude/plugins/cache/$name}"
quiet=false
[ "${1:-}" = "--quiet" ] && quiet=true

[ -f "$manifest" ] || { echo "ERROR: no marketplace manifest at $manifest" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
jq empty "$manifest" 2>/dev/null || { echo "ERROR: $manifest is not valid JSON" >&2; exit 2; }

# Highest version present in the cache for a plugin. Old versions are never cleaned up, so
# "a directory exists" proves nothing — only the newest one matters.
installed_version() {
  [ -d "$cache/$1" ] || return 1
  ls -1 "$cache/$1" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

behind="" missing="" current=0
while IFS=$'\t' read -r plugin want; do
  [ -n "$plugin" ] || continue
  if ! have="$(installed_version "$plugin")" || [ -z "$have" ]; then
    missing="$missing$plugin"$'\n'
  elif [ "$have" = "$want" ]; then
    current=$((current + 1))
  else
    behind="$behind$plugin	$have	$want"$'\n'
  fi
done < <(jq -r '.plugins[] | "\(.name)\t\(.version)"' "$manifest" | tr -d '\r')

n_behind="$(printf '%s' "$behind" | grep -c . || true)"
n_missing="$(printf '%s' "$missing" | grep -c . || true)"

# The manifest is only as fresh as the marketplace clone it came from, and that clone does NOT
# refresh itself. So "everything is current" can mean "current with a copy of the marketplace
# from last week" — a false all-clear, which is worse than no check. Always report the source's
# age; a human can tell instantly whether the answer is worth anything.
src_note=""
src_root="$(dirname "$(dirname "$manifest")")"
if git -C "$src_root" rev-parse --git-dir >/dev/null 2>&1; then
  src_note="$(git -C "$src_root" log -1 --format='%h, last updated %cr' 2>/dev/null)"
fi

staleness_note() {
  [ -n "$src_note" ] || return 0
  printf '    compared against: %s (%s)\n' "$src_root" "$src_note"
  printf '    That copy does not refresh itself. Run `/plugin marketplace update %s`\n' "$name"
  printf '    first if it looks old — otherwise this is only current with a stale list.\n'
}

if [ "$n_behind" -eq 0 ]; then
  # Nothing is stale. Report what is absent, but do NOT fail: a plugin you have not installed
  # yet cannot be serving you old behaviour, which is the only thing this check is for.
  if ! $quiet || [ "$n_missing" -gt 0 ]; then
    printf 'OK: all %d installed plugin(s) match the marketplace (%s)\n' "$current" "$name"
    staleness_note
    if [ "$n_missing" -gt 0 ]; then
      printf '\n  Not installed (not a problem yet): %s\n' "$(printf '%s' "$missing" | tr '\n' ' ')"
      printf '  Onboarding needs ops-install, ops-capabilities and github-ops. Install the loops\n'
      printf '  before you run one:\n\n'
      printf '%s' "$missing" | while read -r p; do
        [ -n "$p" ] || continue
        printf '    /plugin install %s@%s\n' "$p" "$name"
      done
    fi
  fi
  exit 0
fi

printf 'Your installed engine is out of date.\n\n'
printf '  %-20s %-10s %s\n' "PLUGIN" "INSTALLED" "AVAILABLE"
printf '%s' "$behind" | while IFS=$'\t' read -r p h w; do
  [ -n "$p" ] || continue
  printf '  %-20s %-10s %s\n' "$p" "$h" "$w"
done
printf '\n'
staleness_note
if [ "$n_missing" -gt 0 ]; then
  printf '\n  Also not installed (separate matter, not why this failed): %s\n\n' \
    "$(printf '%s' "$missing" | tr '\n' ' ')"
fi

printf 'Run:\n\n  /plugin marketplace update %s\n' "$name"
{ printf '%s' "$behind" | cut -f1; printf '%s' "$missing"; } | sort -u | while read -r p; do
  [ -n "$p" ] || continue
  printf '  /plugin install %s@%s\n' "$p" "$name"
done
cat <<'EOF'

Then RESTART the session — a running session keeps the skills it loaded at start, so an
update with no restart looks like the update did nothing.

Using a cloud environment? Bump the `# rebuild:` number in its Setup script and re-save.
The environment snapshot is busted only by that field's text changing, so a stub that
clones `main` does NOT re-run just because the repo moved on.
EOF
exit 1
