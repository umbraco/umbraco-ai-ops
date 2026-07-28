#!/usr/bin/env bash
# Validate a consumer's routing overlay against the spec's routing rules.
#
# Conformance clause 8(b) — "the installer validates the routing overlay against §6". The
# router deliberately does the minimum it needs to route correctly (valid JSON, events in the
# vocabulary) and no more, because it runs at the edge on every event. Full validation is the
# installer's job, done once, here.
#
# Checks, in the order a reader cares about:
#   * valid JSON, and the shape ops-routing.schema.json describes
#   * every `event` is in the framework vocabulary  (§6.2)
#   * (event, label) is unique — two rules with one key means an ambiguous route  (§6.4)
#   * every non-null `loop` resolves to an installed skill  (§6.6, §8)
#   * a `loop: null` disable actually matches a base rule — otherwise it silently does nothing
#
# Usage:
#   validate-overlay.sh <overlay.json> [skills-dir ...]
#
# Env: BASE_MAP overrides the resolved framework base table.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
engine="${ENGINE_ROOT:-$here/../../../../..}"
base="${BASE_MAP:-$engine/plugins/loop-dispatch/skills/loop-dispatch/scripts/route-map.json}"

overlay="${1:-}"
shift || true
[ -n "$overlay" ] || { echo "usage: $(basename "$0") <overlay.json> [skills-dir ...]" >&2; exit 2; }

fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
warn() { printf 'WARN: %s\n' "$1" >&2; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
[ -f "$overlay" ] || { fail "no overlay at $overlay"; exit 1; }
jq empty "$overlay" 2>/dev/null || { fail "$overlay is not valid JSON"; exit 1; }

VOCAB='["issues.labeled","pull_request.labeled","issues.opened","pull_request.opened"]'

check() { # check <description> <jq filter yielding true>
  local got; got="$(jq -r "$2" "$overlay" 2>/dev/null | tr -d '\r')"
  [ "$got" = "true" ] || fail "$1"
}

# --- shape ---------------------------------------------------------------
check "top-level keys must be exactly version and routes" \
  '(keys_unsorted | sort) == ["routes","version"]'
check "version must be 2, matching the base table's rule shape" '.version == 2'
check "routes must be an array" '.routes | type == "array"'
check "every rule must carry exactly event, label and loop" \
  '.routes | all((keys_unsorted | sort) == ["event","label","loop"])'
check "event and label must be strings" \
  '.routes | all((.event | type == "string") and (.label | type == "string"))'
check "loop must be a string or null" \
  '.routes | all(.loop == null or (.loop | type == "string"))'
check "a non-null loop must match ^[a-z][a-z0-9-]*$" \
  '.routes | all(.loop == null or (.loop | test("^[a-z][a-z0-9-]*$")))'
check "no rule may target the reserved \"none\" sentinel" '.routes | all(.loop != "none")'

# --- the event vocabulary (§6.2) -----------------------------------------
check "every event must come from the framework vocabulary" \
  "[.routes[].event] | all(. as \$e | $VOCAB | index(\$e) != null)"
bad="$(jq -r "[.routes[].event] | map(select(. as \$e | $VOCAB | index(\$e) == null)) | unique | join(\", \")" "$overlay" 2>/dev/null | tr -d '\r')"
[ -z "$bad" ] || fail "  invented event string(s): $bad — a repo MUST NOT invent one outside the vocabulary"

# --- rule identity (§6.4) ------------------------------------------------
check "(event, label) must be unique within the overlay" \
  '([.routes[] | [.event, .label]] | length) == ([.routes[] | [.event, .label]] | unique | length)'

# --- a disable must actually disable something ---------------------------
if [ -f "$base" ] && jq empty "$base" 2>/dev/null; then
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    # `any(. == $k)`, not `index($k)`: jq's index with an ARRAY argument searches for a
    # subsequence, not an element, so index([e,l]) would look for e followed by l.
    if ! jq -e --argjson k "$key" '[.routes[] | [.event, .label]] | any(. == $k)' "$base" >/dev/null 2>&1; then
      warn "a rule disables $key, but the base table has no such rule — the disable does nothing"
    fi
  done < <(jq -c '.routes[] | select(.loop == null) | [.event, .label]' "$overlay" 2>/dev/null | tr -d '\r')
else
  warn "no readable base table at $base — cannot check whether a disable matches anything"
fi

# --- every loop resolves to an installed skill (§6.6) --------------------
dirs=("$@")
[ ${#dirs[@]} -gt 0 ] || dirs=("$engine/plugins")
installed=""
for d in "${dirs[@]}"; do
  [ -d "$d" ] || continue
  installed="$installed$(find "$d" -type f -name SKILL.md 2>/dev/null | sed -n 's#.*/\([^/]*\)/SKILL\.md$#\1#p')
"
done
while IFS= read -r loop; do
  [ -n "$loop" ] || continue
  printf '%s\n' "$installed" | grep -qx "$loop" \
    || fail "loop '$loop' does not resolve to an installed skill — the router would fire a routine that cannot run"
done < <(jq -r '.routes[] | select(.loop != null) | .loop' "$overlay" 2>/dev/null | tr -d '\r')

n="$(jq '.routes | length' "$overlay" 2>/dev/null | tr -d '\r')"
if [ "$fails" -gt 0 ]; then
  printf '\n%s: %d problem(s)\n' "$overlay" "$fails" >&2
  exit 1
fi
printf 'OK: %s — %s overlay rule(s), all conformant\n' "$overlay" "${n:-0}"
