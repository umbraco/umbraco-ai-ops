#!/usr/bin/env bash
# Validate the capability catalog against catalog.schema.json's rules.
#
# CI is hermetic (bash + jq only), so there is no JSON-Schema validator available
# and the schema's rules are re-expressed here in jq. The schema is the readable
# contract; this script is the enforced one. Keep them in step.
#
# It also checks the two things JSON Schema cannot express at all: that capability
# names are unique, and that action names are unique within a capability.
#
# Usage:  validate-catalog.sh [catalog.json]
#         CATALOG_FILE=/path/to/catalog.json validate-catalog.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
catalog="${1:-${CATALOG_FILE:-$here/../catalog.json}}"

fails=0
fail() { printf 'FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

[ -f "$catalog" ] || { fail "no catalog at $catalog"; exit 1; }
jq empty "$catalog" 2>/dev/null || { fail "$catalog is not valid JSON"; exit 1; }

# --- top level -------------------------------------------------------------
check() {
  # check <description> <jq filter that must yield exactly "true">
  local what="$1" filter="$2" got
  got="$(jq -r "$filter" "$catalog" 2>/dev/null)"
  [ "$got" = "true" ] || fail "$what"
}

check "version must be 1" '.version == 1'
check "top-level keys must be exactly version, reserved_skill_names, capabilities" \
  '(keys_unsorted | sort) == ["capabilities","reserved_skill_names","version"]'
check "capabilities must be a non-empty array" '(.capabilities | type == "array" and length > 0)'
check "reserved_skill_names must be a non-empty array of unique slugs" \
  '(.reserved_skill_names | type == "array" and length > 0 and (length == (unique | length)) and all(test("^[a-z][a-z0-9-]*$")))'

# --- per capability --------------------------------------------------------
check "capability names must be unique" \
  '([.capabilities[].capability] | length == (unique | length))'
check "every capability must carry exactly the required keys" \
  '.capabilities | all((keys_unsorted | sort) == ["capability","description","framework_default","kind","operations","visibility"])'
check "every capability name must match ^[a-z][a-z0-9-]*$" \
  '.capabilities | all(.capability | test("^[a-z][a-z0-9-]*$"))'
check "every kind must be behavioral or data" \
  '.capabilities | all(.kind as $k | ["behavioral","data"] | index($k) != null)'
check "every visibility must be service, supporting or cross-cutting" \
  '.capabilities | all(.visibility as $v | ["service","supporting","cross-cutting"] | index($v) != null)'
check "every framework_default must be a boolean" \
  '.capabilities | all(.framework_default | type == "boolean")'
check "every capability description must be a non-empty string" \
  '.capabilities | all(.description | type == "string" and length > 0)'
check "every capability must declare at least one operation" \
  '.capabilities | all(.operations | type == "array" and length > 0)'

# A repo's capability skill is ops-<capability>, so a capability whose prefixed
# name is reserved could never be implemented.
check "no ops-<capability> may collide with a reserved skill name" \
  '(.reserved_skill_names) as $r | .capabilities | all(("ops-" + .capability) as $n | $r | index($n) == null)'

# --- per operation ---------------------------------------------------------
check "action names must be unique within their capability" \
  '.capabilities | all([.operations[].action] | length == (unique | length))'
check "every operation must carry action, description and example" \
  '.capabilities | all(.operations | all(has("action") and has("description") and has("example")))'
check "every operation key must be one of action, description, input, output, example" \
  '.capabilities | all(.operations | all(keys_unsorted | all(. as $k | ["action","description","input","output","example"] | index($k) != null)))'
check "every action must match ^[a-z][a-z0-9-]*$" \
  '.capabilities | all(.operations | all(.action | test("^[a-z][a-z0-9-]*$")))'
check "every operation description must be a non-empty string" \
  '.capabilities | all(.operations | all(.description | type == "string" and length > 0))'
check "every example must be an object" \
  '.capabilities | all(.operations | all(.example | type == "object"))'
check "input and output, where present, must be objects" \
  '.capabilities | all(.operations | all((has("input") | not) or (.input | type == "object")) and all((has("output") | not) or (.output | type == "object")))'

if [ "$fails" -gt 0 ]; then
  printf '\n%s: %d check(s) failed\n' "$catalog" "$fails" >&2
  exit 1
fi

printf 'OK: %s — %s capabilities, %s actions\n' \
  "$catalog" \
  "$(jq '.capabilities | length' "$catalog")" \
  "$(jq '[.capabilities[].operations | length] | add' "$catalog")"
