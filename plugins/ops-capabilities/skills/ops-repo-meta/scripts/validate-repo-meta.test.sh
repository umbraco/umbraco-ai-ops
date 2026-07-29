#!/usr/bin/env bash
# Tests for validate-repo-meta.sh. Hermetic: bash + jq only, no network.
#
# The two cases that matter most are the ones a JSON Schema would miss: `primary` outside
# `live`, and any attempt to put a retired config key back.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/validate-repo-meta.sh"
EXAMPLE="$HERE/ops-repo-meta.example.json"
[ -f "$V" ] || { echo "FATAL: validate-repo-meta.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mk() { printf '%s' "$2" > "$TMP/$1.json"; printf '%s' "$TMP/$1.json"; }
status() { # status <name> <want-rc> <file-or-dir>
  bash "$V" "$3" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want exit $2, got $got"; fi
}
says() { # says <name> <file> <substring>
  local out; out="$(bash "$V" "$2" 2>&1)"
  if printf '%s' "$out" | grep -qF "$3"; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $1 — [$3] not in output"; fi
}
lacks() { # lacks <name> <file> <substring>
  local out; out="$(bash "$V" "$2" 2>&1)"
  if printf '%s' "$out" | grep -qF "$3"; then fail=$((fail+1)); echo "FAIL: $1 — [$3] IS in output"
  else pass=$((pass+1)); fi
}

# --- the shipped example, and the two real consumers ----------------------
status "the shipped example" 0 "$EXAMPLE"
status "Forms' shape (split issues, three lines, upward)" 0 \
  "$(mk forms '{"version":1,"topology":{"issues":"umbraco/Umbraco.Forms.Issues"},"lines":{"live":["v13","v17","v18"],"primary":"v17","port_order":"upward"}}')"
status "Automate's shape (no topology, two lines, downward)" 0 \
  "$(mk automate '{"version":1,"lines":{"live":["v17","v18"],"primary":"v18","port_order":"downward"}}')"

# --- absence is a pass, not a failure ------------------------------------
status "a repo with no file at all" 0 "$TMP/does-not-exist.json"
says   "  and it says the defaults apply" "$TMP/does-not-exist.json" "framework defaults apply"
mkdir -p "$TMP/bare"
status "a repo ROOT with no file" 0 "$TMP/bare"

# A repo root containing one is found via .claude/
mkdir -p "$TMP/repo/.claude"
printf '{"version":1}' > "$TMP/repo/.claude/ops-repo-meta.json"
status "a repo root containing one" 0 "$TMP/repo"

# --- minimal and per-block optionality -----------------------------------
status "version alone"          0 "$(mk min '{"version":1}')"
status "topology alone"         0 "$(mk topo '{"version":1,"topology":{"issues":"a/b"}}')"
status "labels alone"           0 "$(mk lab '{"version":1,"labels":{"ready":"needs-ai"}}')"
status "all three roles"        0 "$(mk allroles '{"version":1,"topology":{"issues":"a/b","releases":"a/c","learnings":"a/d"}}')"
status "a single live line"     0 "$(mk oneline '{"version":1,"lines":{"live":["v18"],"primary":"v18","port_order":"upward"}}')"

# --- the cross-field rule JSON Schema cannot express ---------------------
bad="$(mk badprimary '{"version":1,"lines":{"live":["v17","v18"],"primary":"v19","port_order":"downward"}}')"
status "primary outside live" 1 "$bad"
says   "  and it names both" "$bad" "primary 'v19' is not in live [v17, v18]"
says   "  and says what would break" "$bad" "rooted on a line nobody merges into"

# --- live ordering: a warning, because it cannot be a rule ----------------
# The 29-07-2026 bug: `ops-install` seeded `live` from a newest-first detection, so onboarding
# wrote ["v18","v17"] and `ops-port-loop` found zero targets for every change on the primary
# line. Zero targets is a legitimate outcome, so nothing failed. Ordering cannot be a hard error
# (a line name is an arbitrary string), so it warns and still passes.
rev="$(mk reversed '{"version":1,"lines":{"live":["v18","v17"],"primary":"v18","port_order":"downward"}}')"
status "a reversed live array still passes" 0 "$rev"
says   "  but it warns"            "$rev" "WARN"
says   "  and names the array"     "$rev" "live [v18, v17] is not in ascending version order"
says   "  and says what breaks"    "$rev" "no port targets and never errors"

lacks "an ascending live array does not warn" \
  "$(mk ascending '{"version":1,"lines":{"live":["v13","v17","v18"],"primary":"v17","port_order":"upward"}}')" "WARN"
lacks "a single line cannot be misordered" \
  "$(mk onelinewarn '{"version":1,"lines":{"live":["v18"],"primary":"v18","port_order":"upward"}}')" "WARN"
# Non-`vN` names have no numeric order to read, so the heuristic must stay silent rather than
# guess. `default` is a documented line name.
lacks "non-numeric line names are never judged" \
  "$(mk named '{"version":1,"lines":{"live":["default","legacy"],"primary":"default","port_order":"upward"}}')" "WARN"
lacks "one non-numeric name disables the heuristic" \
  "$(mk mixed '{"version":1,"lines":{"live":["v18","legacy"],"primary":"v18","port_order":"downward"}}')" "WARN"
lacks "a file with no lines block is not judged" "$(mk nolines '{"version":1}')" "WARN"
# Two digits vs one: a string sort would call ["v9","v10"] descending. This compares numbers.
lacks "v9 before v10 is ascending, not descending" \
  "$(mk twodigit '{"version":1,"lines":{"live":["v9","v10"],"primary":"v10","port_order":"downward"}}')" "WARN"

# --- retired config keys must not come back ------------------------------
for k in ci branching playbook repos learning version_pin release_skill; do
  f="$(mk "creep-$k" "{\"version\":1,\"$k\":{}}")"
  [ "$k" = "version_pin" ] && f="$(mk creep-vp '{"version":1,"version_pin":1}')"
  status "a retired key ($k) is rejected" 1 "$f"
done
says "  and it says why" "$(mk creepwhy '{"version":1,"ci":{"provider":"azure-pipelines"}}')" \
  "exactly one owner elsewhere"

# --- the issues side of a split topology ---------------------------------
# This file lives on the ISSUES repo, where detection reads the issues repo's own remote, so
# `code` is the one thing only a declaration can supply. The edge router reads it to resolve
# which repo a routine should work in.
status "topology.code is declarable" 0 "$(mk code '{"version":1,"topology":{"code":"umbraco/Forms"}}')"
status "all four roles at once"      0 \
  "$(mk fourroles '{"version":1,"topology":{"code":"a/b","issues":"a/c","releases":"a/d","learnings":"a/e"}}')"

# --- shape violations ----------------------------------------------------
status "not JSON"                  1 "$(mk broken '{ nope')"
status "the wrong version"          1 "$(mk v2 '{"version":2}')"
status "a missing version"          1 "$(mk nov '{"topology":{"issues":"a/b"}}')"
status "an invented role"           1 "$(mk badrole '{"version":1,"topology":{"tests":"a/b"}}')"
status "a repo value with no slash" 1 "$(mk noslash '{"version":1,"topology":{"issues":"justaname"}}')"
status "a repo value with a space"  1 "$(mk space '{"version":1,"topology":{"issues":"a b/c"}}')"
status "an unknown lines key"       1 "$(mk xlines '{"version":1,"lines":{"live":["v1"],"primary":"v1","port_order":"upward","base":"v1/dev"}}')"
status "a lines block missing primary" 1 "$(mk nopri '{"version":1,"lines":{"live":["v1"],"port_order":"upward"}}')"
status "a lines block missing port_order" 1 "$(mk nopo '{"version":1,"lines":{"live":["v1"],"primary":"v1"}}')"
status "an empty live array"        1 "$(mk emptylive '{"version":1,"lines":{"live":[],"primary":"v1","port_order":"upward"}}')"
status "a duplicated live line"     1 "$(mk duplive '{"version":1,"lines":{"live":["v1","v1"],"primary":"v1","port_order":"upward"}}')"
status "a line name with a capital" 1 "$(mk shoutline '{"version":1,"lines":{"live":["V18"],"primary":"V18","port_order":"upward"}}')"
status "a line name that is a branch" 1 "$(mk branchline '{"version":1,"lines":{"live":["v18/dev"],"primary":"v18/dev","port_order":"upward"}}')"
status "an unknown port_order"      1 "$(mk badpo '{"version":1,"lines":{"live":["v1"],"primary":"v1","port_order":"sideways"}}')"
status "a label keyed by name not purpose" 1 "$(mk badlbl '{"version":1,"labels":{"ops/ready-for-ai":"x"}}')"
status "an empty label value"       1 "$(mk emptylbl '{"version":1,"labels":{"ready":""}}')"

# --- a repo label that is not ops/-namespaced is allowed -----------------
status "an override pointing at a pre-existing label" 0 \
  "$(mk preexisting '{"version":1,"labels":{"ready":"triage/ai-ready"}}')"

# --- usage ---------------------------------------------------------------
bash "$V" >/dev/null 2>&1
if [ $? = 2 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: no argument should exit 2"; fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
