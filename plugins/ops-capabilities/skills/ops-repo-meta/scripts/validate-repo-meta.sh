#!/usr/bin/env bash
# Validate a consumer's .claude/ops-repo-meta.json against ops-repo-meta.schema.json.
#
# Hermetic CI has no JSON-Schema validator, so the schema's rules are re-expressed here in jq.
# The schema is the readable contract; this is the enforced one. Keep them in step.
#
# It also enforces the one rule JSON Schema cannot express: `primary` must be a member of
# `live`. That is not a nicety. A primary line that is not live makes `ops-branching` resolve a
# base nobody merges into, so work gets rooted on a dead branch and the wrong-base gate then
# rejects the PR it produced. Nothing about that failure points at this file.
#
# Every key is optional except `version`. A single-repo project on one line needs no file, and
# "no file" is a pass — call it with a path that does not exist and it says so and exits 0.
#
# Usage:
#   validate-repo-meta.sh <repo-root-or-file>
set -uo pipefail

target="${1:-}"
[ -n "$target" ] || { echo "usage: $(basename "$0") <repo-root|ops-repo-meta.json>" >&2; exit 2; }

# Accept either the file or the repo root that contains it.
file="$target"
[ -d "$target" ] && file="$target/.claude/ops-repo-meta.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

if [ ! -f "$file" ]; then
  echo "OK: no $file — the framework defaults apply (single repo, one line)"
  exit 0
fi
jq empty "$file" 2>/dev/null || { echo "FAIL: $file is not valid JSON" >&2; exit 1; }

fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }
check() { # check <description> <jq filter yielding true>
  local got; got="$(jq -r "$2" "$file" 2>/dev/null | tr -d '\r')"
  [ "$got" = "true" ] || fail "$1"
}

ROLES='["code","issues","releases","learnings"]'
PURPOSES='["ready","in_progress","done","blocked","land","rework","port","release","release_blocked","proto_learning","triaged","loop_improvement"]'
REPO_RE='^[^/[:space:]]+/[^/[:space:]]+$'
LINE_RE='^[a-z0-9][a-z0-9.-]*$'

# --- top level ------------------------------------------------------------
check "version must be 1" '.version == 1'
check "top-level keys must be only version, topology, lines, labels" \
  '[keys_unsorted[] | select(. as $k | ["version","topology","lines","labels"] | index($k) == null)] | length == 0'
bad="$(jq -r '[keys_unsorted[] | select(. as $k | ["version","topology","lines","labels"] | index($k) == null)] | join(", ")' "$file" 2>/dev/null | tr -d '\r')"
[ -z "$bad" ] || fail "  unknown key(s): $bad — branch model, base, merge strategy, CI provider and skill pointers each have exactly one owner elsewhere and MUST NOT come back here"

# --- topology -------------------------------------------------------------
check "topology must be an object" '(has("topology") | not) or (.topology | type == "object")'
check "topology roles must be only code, issues, releases, learnings" \
  "(has(\"topology\") | not) or ([.topology | keys_unsorted[] | select(. as \$k | $ROLES | index(\$k) == null)] | length == 0)"
bad="$(jq -r "[.topology // {} | keys_unsorted[] | select(. as \$k | $ROLES | index(\$k) == null)] | join(\", \")" "$file" 2>/dev/null | tr -d '\r')"
[ -z "$bad" ] || fail "  unknown role(s): $bad — a role left out resolves to the repo this file is in, so an invented one would be silently ignored"
check "every topology value must be owner/name" \
  "(has(\"topology\") | not) or ([.topology[] | select(test(\"$REPO_RE\") | not)] | length == 0)"

# --- lines ----------------------------------------------------------------
check "lines must be an object" '(has("lines") | not) or (.lines | type == "object")'
check "lines keys must be only live, primary, port_order" \
  '(has("lines") | not) or ([.lines | keys_unsorted[] | select(. as $k | ["live","primary","port_order"] | index($k) == null)] | length == 0)'
check "a lines block must declare all three of live, primary, port_order" \
  '(has("lines") | not) or (.lines | has("live") and has("primary") and has("port_order"))'
check "live must be a non-empty array of unique line names" \
  "(has(\"lines\") | not) or (.lines.live | type == \"array\" and length > 0 and (length == (unique | length)) and all(type == \"string\" and test(\"$LINE_RE\")))"
check "primary must be a line name" \
  "(has(\"lines\") | not) or (.lines.primary | type == \"string\" and test(\"$LINE_RE\"))"
check "port_order must be upward or downward" \
  '(has("lines") | not) or (.lines.port_order as $p | ["upward","downward"] | index($p) != null)'

# The cross-field rule JSON Schema cannot express.
check "primary must be one of the live lines" \
  '(has("lines") | not) or (.lines | (.primary as $p | .live | index($p)) != null)'
if [ "$(jq -r '(has("lines") | not) or (.lines | (.primary as $p | .live | index($p)) != null)' "$file" 2>/dev/null | tr -d '\r')" != "true" ]; then
  fail "  primary '$(jq -r '.lines.primary' "$file" | tr -d '\r')' is not in live [$(jq -r '.lines.live | join(", ")' "$file" | tr -d '\r')] — work would be rooted on a line nobody merges into"
fi

# --- labels ---------------------------------------------------------------
check "labels must be an object" '(has("labels") | not) or (.labels | type == "object")'
check "label keys must be purposes, not label names" \
  "(has(\"labels\") | not) or ([.labels | keys_unsorted[] | select(. as \$k | $PURPOSES | index(\$k) == null)] | length == 0)"
bad="$(jq -r "[.labels // {} | keys_unsorted[] | select(. as \$k | $PURPOSES | index(\$k) == null)] | join(\", \")" "$file" 2>/dev/null | tr -d '\r')"
[ -z "$bad" ] || fail "  unknown label purpose(s): $bad — a caller asks for a purpose, so an unknown key is never read"
check "every label must be a non-empty string" \
  '(has("labels") | not) or ([.labels[] | select((type == "string" and length > 0) | not)] | length == 0)'

if [ "$fails" -gt 0 ]; then
  printf '\n%s: %d problem(s)\n' "$file" "$fails" >&2
  exit 1
fi

roles="$(jq -r '[.topology // {} | keys_unsorted[]] | length' "$file" | tr -d '\r')"
lines="$(jq -r 'if has("lines") then (.lines.live | length | tostring) else "0" end' "$file" | tr -d '\r')"
labels="$(jq -r '[.labels // {} | keys_unsorted[]] | length' "$file" | tr -d '\r')"
printf 'OK: %s — %s declared role(s), %s live line(s), %s label override(s)\n' "$file" "$roles" "$lines" "$labels"
