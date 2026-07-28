#!/usr/bin/env bash
# Tests for validate-catalog.sh — mutates a minimal valid catalog with jq and
# asserts each rule rejects. Hermetic: bash + jq only, no network.
#
# Usage: bash validate-catalog.test.sh   (exits non-zero if any case fails)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATE="$HERE/validate-catalog.sh"
REAL="$HERE/../catalog.json"
[ -f "$VALIDATE" ] || { echo "FATAL: validate-catalog.sh not found at $VALIDATE"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

accepts() { # accepts <name> <file>
  if bash "$VALIDATE" "$2" >/dev/null 2>&1
  then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $1 — expected accept, got reject"
  fi
}
rejects() { # rejects <name> <file>
  if bash "$VALIDATE" "$2" >/dev/null 2>&1
  then fail=$((fail+1)); echo "FAIL: $1 — expected reject, got accept"
  else pass=$((pass+1))
  fi
}
mutate() { # mutate <name> <jq filter> -> prints the mutated file path
  local out="$TMP/$1.json"
  jq "$2" "$TMP/valid.json" > "$out"
  printf '%s' "$out"
}

# --- the minimal valid catalog every case starts from ----------------------
cat > "$TMP/valid.json" <<'JSON'
{
  "version": 1,
  "reserved_skill_names": ["ops-issue-loop"],
  "capabilities": [
    {
      "capability": "change",
      "kind": "behavioral",
      "visibility": "service",
      "framework_default": false,
      "description": "Build one change.",
      "operations": [
        { "action": "implement", "description": "Do it.", "example": { "line": "v17" } },
        { "action": "verify",    "description": "Prove it.", "example": {} }
      ]
    }
  ]
}
JSON

accepts "the minimal valid catalog"        "$TMP/valid.json"
accepts "the real catalog in this repo"    "$REAL"

# --- structural rejections -------------------------------------------------
printf '{ not json' > "$TMP/broken.json"
rejects "invalid JSON"                     "$TMP/broken.json"
rejects "a missing file"                   "$TMP/does-not-exist.json"

rejects "wrong version"                    "$(mutate wrong-version '.version = 2')"
rejects "an unknown top-level key"         "$(mutate extra-top '.extra = true')"
rejects "no capabilities"                  "$(mutate no-caps '.capabilities = []')"
rejects "reserved_skill_names missing"     "$(mutate no-reserved 'del(.reserved_skill_names)')"
rejects "a duplicated reserved name"       "$(mutate dup-reserved '.reserved_skill_names += ["ops-issue-loop"]')"

# --- capability rejections -------------------------------------------------
rejects "a duplicated capability name" \
  "$(mutate dup-cap '.capabilities += [.capabilities[0]]')"
rejects "an unknown capability key" \
  "$(mutate extra-cap-key '.capabilities[0].note = "hi"')"
rejects "a missing capability key" \
  "$(mutate no-visibility 'del(.capabilities[0].visibility)')"
rejects "a capability name with a capital" \
  "$(mutate shouty-cap '.capabilities[0].capability = "Change"')"
rejects "an unknown visibility" \
  "$(mutate bad-visibility '.capabilities[0].visibility = "public"')"
rejects "an unknown kind" \
  "$(mutate bad-kind '.capabilities[0].kind = "mechanical"')"
rejects "framework_default as a string" \
  "$(mutate string-default '.capabilities[0].framework_default = "yes"')"
rejects "an empty capability description" \
  "$(mutate empty-desc '.capabilities[0].description = ""')"
rejects "a capability with no operations" \
  "$(mutate no-ops '.capabilities[0].operations = []')"
rejects "ops-<capability> colliding with a reserved name" \
  "$(mutate reserved-collision '.reserved_skill_names += ["ops-change"]')"

# --- operation rejections --------------------------------------------------
rejects "a duplicated action within a capability" \
  "$(mutate dup-action '.capabilities[0].operations += [.capabilities[0].operations[0]]')"
rejects "an action missing its example" \
  "$(mutate no-example 'del(.capabilities[0].operations[0].example)')"
rejects "an action missing its description" \
  "$(mutate no-op-desc 'del(.capabilities[0].operations[0].description)')"
rejects "an empty action description" \
  "$(mutate empty-op-desc '.capabilities[0].operations[0].description = ""')"
rejects "an unknown operation key" \
  "$(mutate extra-op-key '.capabilities[0].operations[0].todo = "later"')"
rejects "an action name with an underscore" \
  "$(mutate snake-action '.capabilities[0].operations[0].action = "close_issue"')"
rejects "an example that is not an object" \
  "$(mutate array-example '.capabilities[0].operations[0].example = []')"
rejects "an input that is not an object" \
  "$(mutate string-input '.capabilities[0].operations[0].input = "a branch"')"

# --- things that must stay legal ------------------------------------------
accepts "an empty example (the action takes no context)" \
  "$(mutate empty-example '.capabilities[0].operations[0].example = {}')"
accepts "input and output omitted entirely" \
  "$(mutate no-io 'del(.capabilities[0].operations[0].input, .capabilities[0].operations[0].output)')"

# --- override_when ---------------------------------------------------------
# The field the installer reads to ask "does this default actually fit your repo?" — the one
# thing coverage cannot check, since it matches skill NAMES, so an inherited default that is
# wrong for this repo reports a clean `inherited` and only fails at run time.
#
# The fixture's single capability is always-repo-provided, so start by making it a default.
DEF='.capabilities[0].framework_default = true | .capabilities[0].override_when = "when X."'
accepts "a framework default that says when to override it" \
  "$(mutate ok-override "$DEF")"
rejects "a framework default with no override_when" \
  "$(mutate no-override '.capabilities[0].framework_default = true')"
rejects "an empty override_when" \
  "$(mutate empty-override "$DEF | .capabilities[0].override_when = \"\"")"
rejects "override_when on an always-repo-provided capability" \
  "$(mutate override-on-repo-cap '.capabilities[0].override_when = "nope"')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
