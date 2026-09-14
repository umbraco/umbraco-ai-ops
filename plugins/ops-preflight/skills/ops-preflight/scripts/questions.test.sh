#!/usr/bin/env bash
# Tests for questions.sh. Hermetic: bash + jq only, nothing filed, no network.
#
# WHAT THIS GUARDS is mostly what must NOT appear. A question nobody can answer, a question the
# files already settled, and a question already answered are three different kinds of noise, and
# putting any of them in front of a person is how an interview gets abandoned halfway.
#
# The ORDER is the other half. The skill says must-haves first, then the report's section order.
# This list is what the interview reads from, so if the two disagree the skill is wrong in practice
# whatever it says on paper.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q="$HERE/questions.sh"
[ -f "$Q" ] || { echo "FATAL: questions.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }
w() { printf '%s' "$2" > "$TMP/$1"; printf '%s' "$TMP/$1"; }

# Deliberately out of order in the file, so any ordering seen below is this script's doing.
FIND="$(w findings.json '{
  "repo":"/x","sources":[],
  "findings":[
    {"id":"q-misc","severity":"quality","section":"Misc","title":"t","why":"w",
     "ask":"A nice-to-have in misc?","verdict":"unknown","evidence_strong":[],"evidence_weak":[]},
    {"id":"b-harness","severity":"blocking","section":"Harness","title":"t","why":"w",
     "ask":"A must-have in harness?","verdict":"unknown","evidence_strong":[],"evidence_weak":["build.sh"]},
    {"id":"b-release","severity":"blocking","section":"Release management","title":"t","why":"w",
     "ask":"A must-have in release?","verdict":"unknown","evidence_strong":[],"evidence_weak":[]},
    {"id":"q-testing","severity":"quality","section":"Testing","title":"t","why":"w",
     "ask":"A nice-to-have in testing?","verdict":"unknown","evidence_strong":[],"evidence_weak":[]},
    {"id":"already-found","severity":"blocking","section":"Harness","title":"t","why":"w",
     "ask":"Detection settled this one","verdict":"present","evidence_strong":["x"],"evidence_weak":[]},
    {"id":"no-question","severity":"blocking","section":"Harness","title":"t","why":"w",
     "verdict":"unknown","evidence_strong":[],"evidence_weak":[]}
  ]}')"

ids() { bash "$Q" "$FIND" ${1:+"$1"} --json 2>/dev/null | jq -r '[.[].id] | join(",")'; }

# --- the order is the skill's order, not the report's ----------------------------
# Must-haves first regardless of section, then the section order the report uses, then by id.
check "must-haves first, then sections, then id" \
  "b-release,b-harness,q-testing,q-misc" "$(ids)"

# --- what must never be asked ----------------------------------------------------
check "a check detection already settled is not asked" 0 \
  "$(bash "$Q" "$FIND" --json 2>/dev/null | jq '[.[] | select(.id=="already-found")] | length')"
check "a check with no question is not asked"          0 \
  "$(bash "$Q" "$FIND" --json 2>/dev/null | jq '[.[] | select(.id=="no-question")] | length')"

# --- what was already found is carried, to open the question with ----------------
check "a weak match rides along with its question" "build.sh" \
  "$(bash "$Q" "$FIND" --json 2>/dev/null | jq -r '.[] | select(.id=="b-harness") | .found[0]')"
check "a check with nothing found carries an empty list" 0 \
  "$(bash "$Q" "$FIND" --json 2>/dev/null | jq '.[] | select(.id=="b-release") | .found | length')"

# --- a second pass shows only what is left ---------------------------------------
# The failure this stops is starting the interview again from the top on a re-run, which is how
# someone ends up answering the same four questions twice and stopping.
A="$(w a.json '{"b-release":"present","q-misc":"gap"}')"
check "answered questions drop off"        "b-harness,q-testing" "$(ids "$A")"
# "I do not know" is not an answer that closes anything: the skill goes and looks, then asks again.
A2="$(w a2.json '{"b-release":"unknown"}')"
check "an 'I do not know' answer stays on the list" 1 \
  "$(bash "$Q" "$FIND" "$A2" --json 2>/dev/null | jq '[.[] | select(.id=="b-release")] | length')"

# --- the text report -------------------------------------------------------------
out="$(bash "$Q" "$FIND" 2>/dev/null)"
check "it says how many are left"              1 "$(printf '%s' "$out" | grep -c 'Still to ask: 4')"
check "it splits must-have from nice-to-have"  1 "$(printf '%s' "$out" | grep -c '^Needed for the loops to work$')"
check "  and names the other group"            1 "$(printf '%s' "$out" | grep -c '^Makes the loops better$')"
check "it says to ask four at a time"          1 "$(printf '%s' "$out" | tr '\n' ' ' | grep -c 'four at a time')"
check "it shows what was already seen"         1 "$(printf '%s' "$out" | grep -c 'already seen: build.sh')"
check "no em dash"                             0 "$(printf '%s' "$out" | grep -c $'\xe2\x80\x94')"

# Nothing left is a real state and must read as finished, not as an error.
ALL="$(w allans.json '{"b-release":"present","b-harness":"present","q-testing":"gap","q-misc":"gap"}')"
out="$(bash "$Q" "$FIND" "$ALL" 2>/dev/null)"
check "nothing left says so plainly" 1 "$(printf '%s' "$out" | grep -c 'Nothing left to ask')"
check "  and points at the score"    1 "$(printf '%s' "$out" | grep -c 'score.sh')"
check "  and still exits 0"          0 "$(bash "$Q" "$FIND" "$ALL" >/dev/null 2>&1; echo $?)"

# --- failure modes ---------------------------------------------------------------
bash "$Q" >/dev/null 2>&1;                          check "no argument exits 2" 2 $?
bash "$Q" "$TMP/nope.json" >/dev/null 2>&1;         check "a missing findings file exits 2" 2 $?
bash "$Q" "$(w notreport.json '{"hello":true}')" >/dev/null 2>&1
check "a file that is not an inspect report exits 2" 2 $?
bash "$Q" "$FIND" "$(w notobj.json '["a"]')" >/dev/null 2>&1
check "an answers file that is not an object exits 2" 2 $?
bash "$Q" "$FIND" "$TMP/nope.json" >/dev/null 2>&1
check "a missing answers file exits 2" 2 $?

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
