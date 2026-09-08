#!/usr/bin/env bash
# Tests for plan-issues.sh. Hermetic: bash + jq only, nothing filed, no network.
#
# Two rules carry the weight here. ONLY A GAP BECOMES AN ISSUE — an `unknown` is a question nobody
# answered, and filing it would convert "we could not see it" into "it is missing". And TITLES ARE
# STABLE, because they are the only thing standing between a second run and a duplicate backlog:
# `create-issue` is not idempotent, so the title is what the skill searches on before it writes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$HERE/plan-issues.sh"
[ -f "$P" ] || { echo "FATAL: plan-issues.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

w() { printf '%s' "$2" > "$TMP/$1.json"; printf '%s' "$TMP/$1.json"; }

F="$(w findings '{
  "repo":"/x","sources":[],
  "findings":[
    {"id":"a-block","consumer":"ops-release","action":"publish","severity":"blocking","section":"Release management","title":"Publishing works","why":"Because it must.","verdict":"unknown","source":null,"evidence":[]},
    {"id":"b-qual","consumer":"ops-change","action":"verify","severity":"quality","section":"Testing","title":"Lint runs","why":"Cheap signal.","verdict":"unknown","source":null,"evidence":[]},
    {"id":"c-seen","consumer":"ops-change","severity":"blocking","section":"Backend","title":"Tests run","why":"Needed.","verdict":"present","source":"detected","evidence":["test.sh"]},
    {"id":"d-noask","consumer":"general","severity":"quality","section":"Misc","title":"Nice to have","why":"Mild.","verdict":"unknown","source":null,"evidence":[]}
  ],
  "summary":{"total":4,"present":1,"unknown":3,"blocking_unknown":1,"interview":3}}')"

plan() { bash "$P" "$F" ${1:+"$1"} --json 2>/dev/null; }
ids()  { printf '%s' "$1" | jq -rc '[.issues[].id]'; }

# --- with no answers, nothing is filed ---------------------------------------
# Three checks are `unknown` and every one of them stays out. Detection alone can never justify
# an issue, because detection alone never establishes that something is missing.
r="$(plan)"
check "no answers means no issues"           0    "$(printf '%s' "$r" | jq '.summary.total')"
check "  even though three are unknown"      '[]' "$(ids "$r")"

# --- only a gap becomes an issue ---------------------------------------------
A="$(w answers '{"a-block":"gap","b-qual":"gap","d-noask":"unknown"}')"
r="$(plan "$A")"
check "two gaps make two issues"             2 "$(printf '%s' "$r" | jq '.summary.total')"
check "  an explicit unknown is left alone"  0 "$(printf '%s' "$r" | jq '[.issues[] | select(.id=="d-noask")] | length')"
check "  a present check is left alone"      0 "$(printf '%s' "$r" | jq '[.issues[] | select(.id=="c-seen")] | length')"
check "  blocking is counted apart"          1 "$(printf '%s' "$r" | jq '.summary.blocking')"
check "  and quality"                        1 "$(printf '%s' "$r" | jq '.summary.quality')"
check "issues come out in section order (Release management before Testing)" \
                                              '["a-block","b-qual"]' "$(ids "$r")"

# --- grouping order matches inspect.sh's report: section first, blocking above quality within it
FS="$(w findings-sect '{
  "repo":"/x","sources":[],
  "findings":[
    {"id":"early-quality","consumer":"general","severity":"quality","section":"Release management","title":"t","why":"w","verdict":"unknown","source":null,"evidence":[]},
    {"id":"late-blocking","consumer":"general","severity":"blocking","section":"Misc","title":"t","why":"w","verdict":"unknown","source":null,"evidence":[]},
    {"id":"same-block","consumer":"general","severity":"blocking","section":"Testing","title":"t","why":"w","verdict":"unknown","source":null,"evidence":[]},
    {"id":"same-qual","consumer":"general","severity":"quality","section":"Testing","title":"t","why":"w","verdict":"unknown","source":null,"evidence":[]}
  ],
  "summary":{"total":4,"present":0,"unknown":4,"blocking_unknown":2,"interview":4}}')"
r="$(bash "$P" "$FS" "$(w allgap '{"early-quality":"gap","late-blocking":"gap","same-block":"gap","same-qual":"gap"}')" --json 2>/dev/null)"
check "a quality gap in an earlier section still sorts before a blocking gap in a later one" \
  "early-quality" "$(printf '%s' "$r" | jq -r '.issues[0].id')"
check "  and within one section, blocking still sorts above quality" \
  '["same-block","same-qual"]' \
  "$(printf '%s' "$r" | jq -c '[.issues[] | select(.section=="Testing") | .id]')"

# An answer may also OVERTURN detection: a human who looks and finds the detected thing is the
# wrong thing must be able to say so, or a false present is unfixable.
r="$(plan "$(w over '{"c-seen":"gap"}')")"
check "a human can overturn a detected present" '["c-seen"]' "$(ids "$r")"
# And confirm one detection missed, without filing anything.
r="$(plan "$(w conf '{"a-block":"present"}')")"
check "a human can confirm what detection missed" 0 "$(printf '%s' "$r" | jq '.summary.total')"

# --- the issue body carries what a reader needs ------------------------------
r="$(plan "$(w one '{"a-block":"gap"}')")"
one="$(printf '%s' "$r" | jq -c '.issues[0]')"
check "the title is prefixed and stable"  "ops-preflight: Publishing works" "$(printf '%s' "$one" | jq -r '.title')"
check "it carries the ops/preflight label" '["ops/preflight"]'              "$(printf '%s' "$one" | jq -c '.labels')"
check "the body opens with the why"        "yes" \
  "$(printf '%s' "$one" | jq -r '.body' | grep -q '^Because it must\.' && echo yes || echo no)"
check "the body names the consumer and action" "yes" \
  "$(printf '%s' "$one" | jq -r '.body' | grep -q 'ops-release publish' && echo yes || echo no)"
check "a blocking body says the capability cannot be written" "yes" \
  "$(printf '%s' "$one" | jq -r '.body' | grep -q 'cannot be written' && echo yes || echo no)"
check "the body names the check id, so a re-run can be traced" "yes" \
  "$(printf '%s' "$one" | jq -r '.body' | grep -q 'a-block' && echo yes || echo no)"
check "the body has no em dash" 0 "$(printf '%s' "$one" | jq -r '.body' | grep -c $'\xe2\x80\x94')"

r="$(plan "$(w q '{"b-qual":"gap"}')")"
check "a quality body says the loops still run" "yes" \
  "$(printf '%s' "$r" | jq -r '.issues[0].body' | grep -q 'loops will run' && echo yes || echo no)"
check "  and does not claim it is blocking"     "no" \
  "$(printf '%s' "$r" | jq -r '.issues[0].body' | grep -q 'cannot be written' && echo yes || echo no)"

# --- titles are stable across runs --------------------------------------------
# This is what makes a second preflight safe. If the title moved, every re-run would file a
# duplicate of everything still open.
check "the same gap produces the same title twice" \
  "$(plan "$(w t1 '{"a-block":"gap"}')" | jq -r '.issues[0].title')" \
  "$(plan "$(w t2 '{"a-block":"gap"}')" | jq -r '.issues[0].title')"

# --- text mode ------------------------------------------------------------------
out="$(bash "$P" "$F" "$A" 2>/dev/null)"
check "text mode lists both issues"                2 "$(printf '%s' "$out" | grep -c 'ops-preflight: ')"
check "text mode says to search the title first"   1 "$(printf '%s' "$out" | grep -c 'SEARCH FOR THE TITLE FIRST')"
check "text mode says to create the label first"   1 "$(printf '%s' "$out" | grep -c 'create-label')"

# Nothing to file is NOT the same as everything passing, and the empty report has to say so —
# it is the exact moment a reader is most likely to conclude the repo is fine.
out="$(bash "$P" "$F" 2>/dev/null)"
check "an empty plan warns that unknown is not a pass" 1 "$(printf '%s' "$out" | grep -c 'unknown is not a pass')"

# --- failure modes -----------------------------------------------------------
bash "$P" >/dev/null 2>&1;                     check "no argument exits 2" 2 $?
bash "$P" "$TMP/absent.json" >/dev/null 2>&1;  check "a missing findings file exits 2" 2 $?
bash "$P" "$(w notreport '{"hello":true}')" >/dev/null 2>&1
check "a file that is not an inspect report exits 2" 2 $?
bash "$P" "$F" "$TMP/absent.json" >/dev/null 2>&1
check "a missing answers file exits 2" 2 $?
bash "$P" "$F" "$(w badjson '{ not json')" >/dev/null 2>&1
check "an unreadable answers file exits 2" 2 $?
bash "$P" "$F" "$(w badarr '["a-block"]')" >/dev/null 2>&1
check "an answers file that is not an object exits 2" 2 $?

# A verdict outside the three is a typo, and the likely typos are the dangerous ones: `missing`
# or `fail` would be silently ignored, so the gap the human just reported would never be filed.
bash "$P" "$F" "$(w badverdict '{"a-block":"missing"}')" >/dev/null 2>&1
check "a verdict outside present|gap|unknown exits 2" 2 $?

# A stale key warns rather than failing — it is harmless on its own, and failing would throw away
# the good answers alongside it.
r="$(bash "$P" "$F" "$(w stale '{"a-block":"gap","ghost":"gap"}')" --json 2>/dev/null)"
check "an answer for an unknown id still plans the real one" '["a-block"]' "$(ids "$r")"
check "  and warns about the stale key" 1 \
  "$(bash "$P" "$F" "$TMP/stale.json" --json 2>&1 >/dev/null | grep -c 'ghost')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
