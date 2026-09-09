#!/usr/bin/env bash
# check-plugin-versions.sh — fail when a plugin's files changed but its plugin.json
# version did not.
#
# WHY. Every plugin ships to users from a version-pinned cache directory,
# ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/. That cache is keyed by
# version, so a plugin whose content changes without its version changing is invisible:
# nobody's cache ever refreshes, however often they update the marketplace. ops-preflight
# sat at 0.1.0 through a full day of false-pass fixes, a new scoring script and evidence
# grading before anyone noticed. validate-manifests.sh cannot catch this — it only checks
# that plugin.json and marketplace.json AGREE on a version, and they always did; neither
# file knows whether that version matches the plugin's actual content.
#
# DESIGN. The comparison needs git history, which is not hermetic. So the decision is a
# pure function, check_plugin_bump, that takes plain string arguments and never touches
# git. check-plugin-versions.test.sh sources this file and calls that function directly
# with fixture data — no git involved. Only main() below calls git, to gather those
# arguments for a real run; main() is guarded so sourcing this file for the function
# never runs it.
#
# WHAT "OLD" AND "NEW" MEAN.
#   - on a pull request: old = the merge base with the PR's target branch (usually
#     main), new = the working tree (the PR's branch, once checked out)
#   - on a push (to main, or run locally with no PR context): old = the previous
#     commit (HEAD~1), new = the working tree
# A plugin absent at "old" is newly added and always passes — there is no prior version
# it could have failed to bump.
#
# CI NOTE: resolving "old" needs enough git history. actions/checkout's default
# (fetch-depth: 1) has neither HEAD~1 nor origin/main available. Give the checkout step
# `fetch-depth: 0` for this to run for real; short of that, this reports the base as
# unresolvable and exits 0 rather than guessing.
#
# Usage:
#   check-plugin-versions.sh [repo-root] [base-ref]
#     repo-root   defaults to the parent of this script's scripts/ directory
#     base-ref    defaults to the merge base with origin/$GITHUB_BASE_REF (or
#                 origin/main) when $GITHUB_EVENT_NAME is pull_request or
#                 pull_request_target, else HEAD~1. Pass explicitly to compare
#                 against anything else.
#
#   check-plugin-versions.sh --help
#     print this usage and exit 0.
#
# Exit codes: 0 all clear (including "nothing to compare"), 1 one or more plugins
# changed without a version bump, 2 usage or environment error (jq/git missing).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: check-plugin-versions.sh [repo-root] [base-ref]

Fails when a plugin's files changed between base-ref and the working tree but its
plugin.json version did not.

  repo-root   defaults to the parent of this script's scripts/ directory
  base-ref    defaults to the merge base with origin/$GITHUB_BASE_REF (or origin/main)
              on a pull request ($GITHUB_EVENT_NAME=pull_request(_target)), else HEAD~1

Exit codes: 0 all clear, 1 a plugin changed without a version bump, 2 usage/env error.
A base-ref that will not resolve (e.g. a shallow checkout) is reported and treated as
"nothing to compare" — exit 0, not an error.
EOF
}

fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# jq on some platforms writes CRLF to a pipe, which would end up inside these values.
strip_cr() { tr -d '\r'; }

# --- pure comparison: no git, so the test can call this directly -----------------
# check_plugin_bump PLUGIN OLD_VERSION NEW_VERSION CHANGED_FILES
#   PLUGIN         name, for the message only
#   OLD_VERSION    version at the base ref; empty means the plugin did not exist there
#                  (newly added) — always passes
#   NEW_VERSION    version now
#   CHANGED_FILES  newline-separated paths that differ between base and now, under the
#                  plugin's own directory (plugin.json included); empty means nothing
#                  changed — always passes
# Fails only when something changed AND the version is unchanged. Prints nothing on
# pass. Returns 0 (pass) or 1 (fail).
check_plugin_bump() {
  local plugin="$1" old="$2" new="$3" files="$4"

  [ -n "$old" ] || return 0
  [ -n "$files" ] || return 0

  if [ "$old" = "$new" ]; then
    local n list
    n="$(printf '%s\n' "$files" | grep -c .)"
    list="$(printf '%s' "$files" | tr '\n' ' ')"
    fail "$plugin: $n file(s) changed under plugins/$plugin/ but version is still $old — bump plugin.json (and its marketplace.json entry) before merging: $list"
    return 1
  fi

  return 0
}

# --- real invocation: gather old/new/changed-files from git for every plugin -----
main() {
  if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
  fi

  local root="${1:-$here/..}"
  local base="${2:-}"

  command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }
  command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 2; }

  if [ -z "$base" ]; then
    if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ "${GITHUB_EVENT_NAME:-}" = "pull_request_target" ]; then
      local target="${GITHUB_BASE_REF:-main}"
      base="$(git -C "$root" merge-base HEAD "origin/$target" 2>/dev/null | strip_cr)"
      [ -n "$base" ] || base="origin/$target"
    else
      base="HEAD~1"
    fi
  fi

  if ! git -C "$root" rev-parse --verify "$base" >/dev/null 2>&1; then
    printf 'SKIP: base ref "%s" does not resolve (shallow checkout? need more git history) — nothing to compare\n' "$base"
    exit 0
  fi

  local checked=0
  for d in "$root"/plugins/*/; do
    [ -d "$d" ] || continue
    local plugin pj_rel old new files
    plugin="$(basename "$d")"
    pj_rel="plugins/$plugin/.claude-plugin/plugin.json"

    old="$(git -C "$root" show "$base:$pj_rel" 2>/dev/null | jq -r '.version // empty' 2>/dev/null | strip_cr)"
    new=""
    [ -f "$root/$pj_rel" ] && new="$(jq -r '.version // empty' "$root/$pj_rel" 2>/dev/null | strip_cr)"
    files="$(git -C "$root" diff --name-only "$base" -- "plugins/$plugin/" 2>/dev/null | strip_cr)"

    check_plugin_bump "$plugin" "$old" "$new" "$files"
    checked=$((checked + 1))
  done

  if [ "$fails" -gt 0 ]; then
    printf '\n%d plugin(s) changed without a version bump\n' "$fails" >&2
    exit 1
  fi
  printf 'OK: %d plugin(s) checked against %s, every change carries a version bump\n' "$checked" "$base"
}

# Sourced (by the test, for check_plugin_bump) vs executed: only run main() when this
# file is the thing that was invoked directly.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
