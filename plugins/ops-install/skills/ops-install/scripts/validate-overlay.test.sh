#!/usr/bin/env bash
# Tests for validate-overlay.sh. Hermetic: bash + jq only, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/validate-overlay.sh"
ENGINE="$HERE/../../../../.."
EXAMPLE="$ENGINE/plugins/loop-dispatch/skills/loop-dispatch/scripts/ops-routing.example.json"
[ -f "$V" ] || { echo "FATAL: validate-overlay.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
status() { # status <name> <want-rc> <overlay>
  bash "$V" "$3" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want exit $2, got $got"; fi
}
mk() { printf '%s' "$2" > "$TMP/$1.json"; printf '%s' "$TMP/$1.json"; }

# --- the shipped example is conformant ------------------------------------
status "the shipped example overlay" 0 "$EXAMPLE"

# --- legal overlays -------------------------------------------------------
status "an empty overlay" 0 "$(mk empty '{"version":2,"routes":[]}')"
status "an added label"   0 "$(mk add   '{"version":2,"routes":[{"event":"issues.labeled","label":"ops/needs-ai","loop":"ops-issue-loop"}]}')"
status "a disable"        0 "$(mk dis   '{"version":2,"routes":[{"event":"pull_request.labeled","label":"ops/auto-rework","loop":null}]}')"
status "a retarget onto another framework loop" 0 \
  "$(mk retarget '{"version":2,"routes":[{"event":"pull_request.labeled","label":"ops/auto-merge","loop":"ops-issue-loop"}]}')"
status "an .opened rule with an empty label" 0 \
  "$(mk opened '{"version":2,"routes":[{"event":"issues.opened","label":"","loop":"ops-triage-loop"}]}')"

# --- shape violations -----------------------------------------------------
status "not JSON"                 1 "$(mk broken '{ nope')"
status "a missing file"           1 "$TMP/absent.json"
status "the wrong version"        1 "$(mk v1  '{"version":1,"routes":[]}')"
status "an extra top-level key"   1 "$(mk xtra '{"version":2,"routes":[],"extra":true}')"
status "routes not an array"      1 "$(mk nota '{"version":2,"routes":{}}')"
status "a missing rule key"       1 "$(mk nokey '{"version":2,"routes":[{"event":"issues.labeled","loop":"ops-issue-loop"}]}')"
status "an extra rule key"        1 "$(mk xkey '{"version":2,"routes":[{"event":"issues.labeled","label":"a","loop":"ops-issue-loop","note":"x"}]}')"
status "a non-string label"       1 "$(mk numlbl '{"version":2,"routes":[{"event":"issues.labeled","label":7,"loop":"ops-issue-loop"}]}')"
status "a loop with a capital"    1 "$(mk shout '{"version":2,"routes":[{"event":"issues.labeled","label":"a","loop":"Ops-Issue-Loop"}]}')"
status "the reserved none sentinel" 1 "$(mk none '{"version":2,"routes":[{"event":"issues.labeled","label":"a","loop":"none"}]}')"

# --- the event vocabulary -------------------------------------------------
status "an invented event"        1 "$(mk badev '{"version":2,"routes":[{"event":"issues.label","label":"a","loop":"ops-issue-loop"}]}')"
status "a raw github event name"  1 "$(mk raw   '{"version":2,"routes":[{"event":"issues","label":"a","loop":"ops-issue-loop"}]}')"
status "an un-normalised pull_request_target" 1 \
  "$(mk pqt '{"version":2,"routes":[{"event":"pull_request_target.labeled","label":"a","loop":"ops-issue-loop"}]}')"

# --- rule identity --------------------------------------------------------
status "a duplicated (event,label)" 1 \
  "$(mk dup '{"version":2,"routes":[{"event":"issues.labeled","label":"a","loop":"ops-issue-loop"},{"event":"issues.labeled","label":"a","loop":"ops-merge-loop"}]}')"
status "the same label on different events is fine" 0 \
  "$(mk twoev '{"version":2,"routes":[{"event":"issues.labeled","label":"a","loop":"ops-issue-loop"},{"event":"pull_request.labeled","label":"a","loop":"ops-merge-loop"}]}')"

# --- loop resolution ------------------------------------------------------
status "a loop that is not installed" 1 \
  "$(mk ghost '{"version":2,"routes":[{"event":"issues.labeled","label":"a","loop":"ghost-loop"}]}')"

# A repo-provided loop skill resolves when its directory is passed in.
mkdir -p "$TMP/repo/.claude/skills/repo-own-loop"
printf -- "---\nname: repo-own-loop\n---\n" > "$TMP/repo/.claude/skills/repo-own-loop/SKILL.md"
own="$(mk own '{"version":2,"routes":[{"event":"issues.labeled","label":"a","loop":"repo-own-loop"}]}')"
bash "$V" "$own" "$ENGINE/plugins" "$TMP/repo/.claude/skills" >/dev/null 2>&1
if [ $? = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a repo-provided loop resolves when its dir is given"; fi
bash "$V" "$own" >/dev/null 2>&1
if [ $? = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a repo-provided loop must NOT resolve from the engine alone"; fi

# --- a disable that matches nothing warns but does not fail ---------------
noop="$(mk noop '{"version":2,"routes":[{"event":"issues.labeled","label":"never-existed","loop":null}]}')"
status "a disable matching no base rule still passes" 0 "$noop"
# Capture, then grep. Under `set -o pipefail`, `cmd | grep -q` reports the WRITER's status
# because grep -q closes the pipe early and cmd dies on SIGPIPE — so the pipeline looks failed
# even on a match. This bit the test before it bit anyone else.
noop_out="$(bash "$V" "$noop" 2>&1)"
if printf '%s' "$noop_out" | grep -q "the disable does nothing"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: a no-op disable should warn"; fi

# --- usage ----------------------------------------------------------------
bash "$V" >/dev/null 2>&1
if [ $? = 2 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: no argument should exit 2"; fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
