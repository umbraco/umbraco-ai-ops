#!/usr/bin/env bash
# Capability coverage report: for every capability the catalog declares, is it
# present / inherited / missing in a target repo?
#
# This is conformance clause 8(a) — "the installer reports each catalogued capability as
# present / inherited / missing by matching ops-<capability> skill names" — done
# deterministically, because a coverage report a model produces by reading directories is a
# coverage report that can be wrong without anyone noticing.
#
#   present    the repo ships .claude/skills/ops-<cap>/SKILL.md
#   inherited  the repo ships none, and the engine has a framework default
#   missing    the repo ships none and there is no default -> nothing will run
#
# Usage:
#   coverage.sh <repo-root> [--json]
#
# Env: CATALOG_FILE, ENGINE_ROOT override the resolved defaults.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$here/engine-root.sh"
engine="$(ops_engine_root "$here")"
catalog="${CATALOG_FILE:-$engine/catalog.json}"

repo="${1:-}"
fmt="${2:-text}"
[ -n "$repo" ] || { echo "usage: $(basename "$0") <repo-root> [--json]" >&2; exit 2; }
# Reject an unknown second argument rather than falling back to text. A caller that asked for
# `--jsonn` and got a human table has to notice the difference to know it was ignored, and the
# exit code is the same either way.
case "$fmt" in text|--json) ;; *) echo "ERROR: unknown option '$fmt' (expected --json)" >&2; exit 2 ;; esac
[ -d "$repo" ] || { echo "ERROR: no such directory: $repo" >&2; exit 2; }
[ -f "$catalog" ] || { echo "ERROR: no catalog at $catalog" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
jq empty "$catalog" 2>/dev/null || { echo "ERROR: catalog is not valid JSON" >&2; exit 2; }

# Framework defaults are skills named ops-<cap> anywhere under the engine's plugins/.
# Read from disk rather than from the catalog's framework_default flag, so the report
# reflects what is actually installable — a flag saying a default exists is a claim, and
# this script's job is to check claims.
# Scan the engine's plugins/ when that layout exists (git checkout); otherwise scan the
# engine root, because installed plugins sit directly under the marketplace directory
# with no intervening plugins/.
defaults=""
search_root="$engine/plugins"; [ -d "$search_root" ] || search_root="$engine"
if [ -d "$search_root" ]; then
  defaults="$(find "$search_root" -type f -name SKILL.md 2>/dev/null \
              | sed -n 's#.*/skills/\(ops-[a-z0-9-]*\)/SKILL\.md$#\1#p' | sort -u)"
fi

rows=""
missing=0 present=0 inherited=0
while IFS= read -r cap; do
  skill="ops-$cap"
  if [ -f "$repo/.claude/skills/$skill/SKILL.md" ]; then
    state="present"; where=".claude/skills/$skill"; present=$((present+1))
  elif printf '%s\n' "$defaults" | grep -qx "$skill"; then
    state="inherited"; where="engine default"; inherited=$((inherited+1))
  else
    state="missing"; where="-"; missing=$((missing+1))
  fi
  # `inherited` is the state that can be quietly wrong. Coverage matches skill NAMES, so a
  # default that does not suit this repo reports a clean `inherited` and fails at run time.
  # Carry the catalog's `override_when` alongside it so the caller can ask a real question
  # instead of showing a row that looks like a pass.
  when=""
  [ "$state" = "inherited" ] && when="$(jq -r --arg c "$cap" \
    '.capabilities[] | select(.capability == $c) | .override_when // ""' "$catalog" | tr -d '\r')"
  rows="$rows$skill	$state	$where	$when
"
done < <(jq -r '.capabilities[].capability' "$catalog" | tr -d '\r')

if [ "$fmt" = "--json" ]; then
  printf '%s' "$rows" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t"))
    | { capabilities: map({ skill: .[0], state: .[1], source: .[2], override_when: (.[3] // "") }),
        summary: { present: (map(select(.[1]=="present")) | length),
                   inherited: (map(select(.[1]=="inherited")) | length),
                   missing: (map(select(.[1]=="missing")) | length) } }'
else
  printf 'Capability coverage for %s\n\n' "$repo"
  printf '%s' "$rows" | while IFS=$'\t' read -r s st w _; do
    [ -n "$s" ] || continue
    printf '  %-18s %-10s %s\n' "$s" "$st" "$w"
  done
  printf '\n  %d present, %d inherited, %d missing\n' "$present" "$inherited" "$missing"
  [ "$missing" -gt 0 ] && printf '\n  A missing capability has no implementation and no default — scaffold a stub for it.\n'

  # Inherited is NOT a clean bill of health, and printing it like one is how a repo finishes
  # onboarding green and fails on its first run.
  if [ "$inherited" -gt 0 ]; then
    printf '\n  %d inherited — this is a NAME match, not a fitness check. Ask about each:\n\n' "$inherited"
    printf '%s' "$rows" | while IFS=$'\t' read -r s st _ when; do
      [ "$st" = "inherited" ] && [ -n "$when" ] || continue
      printf '    %-18s override %s\n' "$s" "$when"
    done
  fi
fi

# Exit 1 when anything is missing, so a caller can gate on coverage.
[ "$missing" -eq 0 ]
