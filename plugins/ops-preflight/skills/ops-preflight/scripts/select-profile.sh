#!/usr/bin/env bash
# Work out which check files apply to a repo, in the order they must be merged.
#
# Three layers, and the order is the whole point — later wins by check `id`:
#
#   1. the engine base            scripts/checks.json                          always
#   2. every matching stack       scripts/profiles/<stack>.json                 by its own `when`
#   3. the repo's own override    <repo>/.claude/ops-preflight-profile.json     if present
#
# Profiles are ADDITIVE. A repo holding both a solution and a package.json loads both, because it
# genuinely has both stacks and both sets of checks are true of it. Nothing picks one winner.
#
# Profiles are named for a STACK, never a product: no product name ships in the engine. A check
# that is only true of one product belongs in that repo's own override file, which is layer 3 and
# exists for exactly this.
#
# Usage:
#   select-profile.sh <repo-root> [--json]
#
# Output: one absolute path per line, base first. --json adds which layer each came from.
set -uo pipefail

repo="" fmt="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) fmt="json"; shift ;;
    -h|--help) echo "usage: $(basename "$0") <repo-root> [--json]"; exit 0 ;;
    *) [ -z "$repo" ] && repo="$1"; shift ;;
  esac
done

[ -n "$repo" ] || { echo "usage: $(basename "$0") <repo-root> [--json]" >&2; exit 2; }
[ -d "$repo" ] || { echo "ERROR: no such directory: $repo" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=detect-lib.sh
. "$HERE/detect-lib.sh"
repo="$(cd "$repo" && pwd)"

# Resolved relative to this script, so the data moves with the code that reads it. The env vars
# are the consumer escape hatch, the same convention every other script in the engine uses.
BASE="${OPS_PREFLIGHT_CHECKS:-$HERE/checks.json}"
PROFILES="${OPS_PREFLIGHT_PROFILES:-$HERE/profiles}"
OVERRIDE="$repo/.claude/ops-preflight-profile.json"

[ -f "$BASE" ] || { echo "ERROR: no base check catalog at $BASE" >&2; exit 2; }
jq empty "$BASE" 2>/dev/null || { echo "ERROR: $BASE is not valid JSON" >&2; exit 2; }

preflight_scan "$repo"

matches_when() { # matches_when <profile-file>
  local f="$1" globs
  # A profile with no `when` never auto-loads. Deliberate: an unconditional stack profile would
  # apply its checks to every repo, which is the one thing profiles exist to prevent.
  jq -e 'has("when")' "$f" >/dev/null 2>&1 || return 1
  mapfile -t globs < <(jq -r '(.when.any_path // [])[]' "$f" 2>/dev/null | tr -d '\r')
  [ "${#globs[@]}" -gt 0 ] || return 1
  preflight_match_any_path "${globs[@]}"
}

rows="[]"
add() { rows="$(printf '%s' "$rows" | jq -c --arg p "$1" --arg l "$2" --arg n "$3" '. + [{path:$p,layer:$l,name:$n}]')"; }

add "$BASE" base base

if [ -d "$PROFILES" ]; then
  # Sorted, so two repos with the same stacks always merge in the same order and a report is
  # reproducible. Stack profiles do not override each other in practice, but "in practice" is not
  # a guarantee and a non-deterministic merge order is impossible to debug after the fact.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if ! jq empty "$f" 2>/dev/null; then echo "WARN: skipping unreadable profile $f" >&2; continue; fi
    if matches_when "$f"; then add "$f" stack "$(jq -r '.profile // "unnamed"' "$f")"; fi
  done < <(find "$PROFILES" -maxdepth 1 -name '*.json' 2>/dev/null | sort)
fi

if [ -f "$OVERRIDE" ]; then
  jq empty "$OVERRIDE" 2>/dev/null || { echo "ERROR: $OVERRIDE is not valid JSON" >&2; exit 2; }
  add "$OVERRIDE" repo "$(jq -r '.profile // "repo"' "$OVERRIDE")"
fi

if [ "$fmt" = "json" ]; then
  printf '%s' "$rows" | jq -c '{
    sources: .,
    summary: {
      total: length,
      stacks: [.[] | select(.layer=="stack") | .name],
      has_repo_override: (any(.[]; .layer=="repo"))
    }
  }'
  exit 0
fi

printf '%s' "$rows" | jq -r '.[].path'
