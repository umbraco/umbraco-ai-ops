#!/usr/bin/env bash
# Tests for score.sh. Hermetic: bash + jq only, nothing filed, no network.
#
# THE WHOLE DESIGN IS ONE RULE: a score is only honest AFTER the interview. So the tests that
# matter most here are the refusal ones: any check still `unknown` and score.sh must print no
# grade and no percentage, however many checks it does already know about. Only once every check
# is `present` or `gap` does a letter appear, and even then a hard cap holds: a blocking `gap`
# never lets the grade read better than C.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/score.sh"
[ -f "$S" ] || { echo "FATAL: score.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

w() { printf '%s' "$2" > "$TMP/$1.json"; printf '%s' "$TMP/$1.json"; }

# A repo with one blocking check still unknown and one quality check still unknown, alongside one
# present each. This is the shape a raw inspect.sh scan actually produces before any interview.
RAW="$(w raw '{
  "repo":"/x","sources":[],
  "findings":[
    {"id":"b-present","consumer":"ops-change","severity":"blocking","section":"Backend","title":"Tests run","why":"w","verdict":"present","source":"detected","evidence":["test.sh"]},
    {"id":"b-unknown","consumer":"ops-release","action":"cut","severity":"blocking","section":"Release management","title":"Release trigger exists","why":"w","verdict":"unknown","source":null,"evidence":[]},
    {"id":"q-present","consumer":"general","severity":"quality","section":"Testing","title":"Lint runs","why":"w","verdict":"present","source":"detected","evidence":[".eslintrc"]},
    {"id":"q-unknown","consumer":"general","severity":"quality","section":"Misc","title":"Docs stay current","why":"w","verdict":"unknown","source":null,"evidence":[]}
  ],
  "summary":{"total":4,"present":2,"unknown":2,"blocking_unknown":1,"interview":2}}')"

score() { bash "$S" "$RAW" ${1:+"$1"} --json 2>/dev/null; }

# --- the one rule: any unknown means no grade, ever ---------------------------
r="$(score)"
check "not ready to grade while anything is unknown"  "false" "$(printf '%s' "$r" | jq -r '.ready_to_grade')"
check "grade is null, not a guess"                    "null"  "$(printf '%s' "$r" | jq -c '.grade')"
check "unknown count is reported"                     2       "$(printf '%s' "$r" | jq '.unknown_count')"
check "the known counts are still reported"           1       "$(printf '%s' "$r" | jq '.counts.severity.blocking.present')"
check "  out of the real total, unknowns included"    2       "$(printf '%s' "$r" | jq '.counts.severity.blocking.total')"

out="$(bash "$S" "$RAW" 2>/dev/null)"
check "text mode prints no grade line while unknown remains" 0 "$(printf '%s' "$out" | grep -c '^Grade:')"
check "text mode says no grade yet"                           1 "$(printf '%s' "$out" | grep -c 'No grade yet')"
check "text mode names how many checks are still unknown"     1 "$(printf '%s' "$out" | grep -c '2 checks are still unknown')"
check "text mode still shows the known counts"                1 "$(printf '%s' "$out" | grep -c 'Needed for the loops to work: 1 of 2 present')"

# --- answering everything, but with a blocking gap: the hard cap -----------------
# Four blocking checks present, one blocking gap, five quality present. Unweighted that scores
# 85%, comfortably an A on the band table, but the cap must still pull it down to C.
CAPFIND="$(w capfind '{
  "repo":"/y","sources":[],
  "findings":[
    {"id":"b1","consumer":"ops-change","severity":"blocking","section":"Backend","title":"t1","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"b2","consumer":"ops-change","severity":"blocking","section":"Backend","title":"t2","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"b3","consumer":"ops-workspace","severity":"blocking","section":"Environment","title":"t3","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"b4","consumer":"ops-integrate","severity":"blocking","section":"Release management","title":"t4","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"b5","consumer":"ops-release","severity":"blocking","section":"Release management","title":"Release trigger exists","why":"w","verdict":"unknown","source":null,"evidence":[]},
    {"id":"q1","consumer":"general","severity":"quality","section":"Testing","title":"q1","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"q2","consumer":"general","severity":"quality","section":"Misc","title":"q2","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"q3","consumer":"general","severity":"quality","section":"Best practices","title":"q3","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"q4","consumer":"ops-release","severity":"quality","section":"Release management","title":"q4","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"q5","consumer":"general","severity":"quality","section":"Utilities","title":"q5","why":"w","verdict":"present","source":"detected","evidence":["x"]}
  ],
  "summary":{"total":10,"present":9,"unknown":1,"blocking_unknown":1,"interview":1}}')"
CAPANS="$(w capans '{"b5":"gap"}')"

r="$(bash "$S" "$CAPFIND" "$CAPANS" --json 2>/dev/null)"
check "answering the last unknown makes it ready"    "true" "$(printf '%s' "$r" | jq -r '.ready_to_grade')"
check "the raw weighted score is 85 percent"         85     "$(printf '%s' "$r" | jq -r '.grade.percent')"
check "a blocking gap caps the letter at C"           "C"   "$(printf '%s' "$r" | jq -r '.grade.letter')"
check "the cap is flagged"                           "true" "$(printf '%s' "$r" | jq -r '.grade.capped')"
check "loops cannot start"                           "false" "$(printf '%s' "$r" | jq -r '.loops_can_start')"
check "the missing blocking check is named"          '["b5"]' "$(printf '%s' "$r" | jq -c '[.blocking_not_present[].id]')"

out="$(bash "$S" "$CAPFIND" "$CAPANS" 2>/dev/null)"
check "text mode prints the capped grade"        1 "$(printf '%s' "$out" | grep -c '^Grade: C (capped). Weighted score 85%')"
check "text mode explains the cap in plain words" 1 "$(printf '%s' "$out" | tr '\n' ' ' | grep -ci 'cannot read better than C')"
check "the cap explanation has no em dash"        0 "$(printf '%s' "$out" | grep -c $'\xe2\x80\x94')"
check "no tone word 'fail' anywhere in the report" 0 "$(printf '%s' "$out" | grep -ci 'fail')"
check "no tone word 'bad' anywhere in the report"  0 "$(printf '%s' "$out" | grep -ci '\bbad\b')"
check "no tone word 'poor' anywhere in the report" 0 "$(printf '%s' "$out" | grep -ci 'poor')"

# --- fully resolved and clean: no cap, a plain band lookup -----------------------
CLEAN="$(w clean '{
  "repo":"/z","sources":[],
  "findings":[
    {"id":"b1","consumer":"ops-change","severity":"blocking","section":"Backend","title":"t1","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"b2","consumer":"ops-change","severity":"blocking","section":"Backend","title":"t2","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"b3","consumer":"ops-workspace","severity":"blocking","section":"Environment","title":"t3","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"b4","consumer":"ops-integrate","severity":"blocking","section":"Release management","title":"t4","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"q1","consumer":"general","severity":"quality","section":"Testing","title":"q1","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"q2","consumer":"general","severity":"quality","section":"Misc","title":"q2","why":"w","verdict":"unknown","source":null,"evidence":[]},
    {"id":"q3","consumer":"general","severity":"quality","section":"Best practices","title":"q3","why":"w","verdict":"present","source":"detected","evidence":["x"]},
    {"id":"q4","consumer":"ops-release","severity":"quality","section":"Release management","title":"q4","why":"w","verdict":"unknown","source":null,"evidence":[]},
    {"id":"q5","consumer":"general","severity":"quality","section":"Utilities","title":"q5","why":"w","verdict":"unknown","source":null,"evidence":[]},
    {"id":"q6","consumer":"general","severity":"quality","section":"Harness","title":"q6","why":"w","verdict":"present","source":"detected","evidence":["x"]}
  ],
  "summary":{"total":10,"present":7,"unknown":3,"blocking_unknown":0,"interview":3}}')"
CLEANANS="$(w cleanans '{"q2":"gap","q4":"gap","q5":"gap"}')"

r="$(bash "$S" "$CLEAN" "$CLEANANS" --json 2>/dev/null)"
check "ready once every unknown is answered"  "true" "$(printf '%s' "$r" | jq -r '.ready_to_grade')"
check "no cap when there is no blocking gap"  "false" "$(printf '%s' "$r" | jq -r '.grade.capped')"
check "the grade is B at 83 percent"          "B"    "$(printf '%s' "$r" | jq -r '.grade.letter')"
check "  at the expected percentage"          83     "$(printf '%s' "$r" | jq -r '.grade.percent')"
check "loops can start: every blocking check is present" "true" "$(printf '%s' "$r" | jq -r '.loops_can_start')"
check "nothing named as a blocker"            "[]"   "$(printf '%s' "$r" | jq -c '.blocking_not_present')"

out="$(bash "$S" "$CLEAN" "$CLEANANS" 2>/dev/null)"
check "text mode prints an uncapped grade line" 1 "$(printf '%s' "$out" | grep -c '^Grade: B (83%)$')"
check "text mode does not print a cap note"     0 "$(printf '%s' "$out" | grep -c 'Capped')"
check "text mode says the loops can start"      1 "$(printf '%s' "$out" | grep -c 'Loops can start: yes')"

# --- band edges -----------------------------------------------------------------
band() {
  # One blocking check, always present, weighted 3. Plus $1 of $2 quality checks present, each
  # weighted 1. The rest of the quality checks come back unknown from detection and are then
  # answered gap, so the report is always fully resolved and ready to grade. That lets one call
  # dial the weighted percentage precisely: pct = (3 + present) / (3 + total) * 100.
  local present="$1" total="$2"
  local findings='{"repo":"/band","sources":[],"findings":[{"id":"b1","consumer":"c","severity":"blocking","section":"Backend","title":"t","why":"w","verdict":"present","source":"detected","evidence":["x"]}'
  local i
  for i in $(seq 1 "$total"); do
    local v="unknown"
    [ "$i" -le "$present" ] && v="present"
    findings+=",{\"id\":\"q$i\",\"consumer\":\"c\",\"severity\":\"quality\",\"section\":\"Misc\",\"title\":\"q$i\",\"why\":\"w\",\"verdict\":\"$v\",\"source\":null,\"evidence\":[]}"
  done
  findings+='],"summary":{}}'
  local f; f="$(w "band_${present}_${total}" "$findings")"
  local a='{}'
  local j tail
  tail="$(seq $((present+1)) "$total" 2>/dev/null || true)"
  for j in $tail; do
    a="$(printf '%s' "$a" | jq -c --arg k "q$j" '. + {($k): "gap"}')"
  done
  local af; af="$(w "bandans_${present}_${total}" "$a")"
  bash "$S" "$f" "$af" --json 2>/dev/null | jq -r '.grade.letter'
}

# Every case sits comfortably inside its band (never on a boundary value), so floating-point
# rounding on the threshold comparison itself can never be the reason a test passes or fails.
check "100 percent bands to A*"  "A*" "$(band 1 1)"     # (3+1)/(3+1)   = 100%
check "90 percent bands to A"    "A"  "$(band 15 17)"   # (3+15)/(3+17) = 90%
check "80 percent bands to B"    "B"  "$(band 13 17)"   # (3+13)/(3+17) = 80%
check "70 percent bands to C"    "C"  "$(band 11 17)"   # (3+11)/(3+17) = 70%
check "60 percent bands to D"    "D"  "$(band 9 17)"    # (3+9)/(3+17)  = 60%
check "50 percent bands to E"    "E"  "$(band 7 17)"    # (3+7)/(3+17)  = 50%
check "under 45 percent bands to F" "F" "$(band 0 20)"  # (3+0)/(3+20)  = 13%

# --- a plain-text call never prints a bare percentage while anything is unknown ---------------
check "text mode never prints a percent sign while ungraded" 0 \
  "$(bash "$S" "$RAW" 2>/dev/null | grep -c '%')"

# --- an answer can resolve one unknown while another is left open ------------------------------
# Answering b-unknown does not make the report ready: q-unknown is still open, and one open
# question is enough to withhold the grade.
r="$(bash "$S" "$RAW" "$(w partial '{"b-unknown":"present"}')" --json 2>/dev/null)"
check "one answered unknown updates the known counts" 2 "$(printf '%s' "$r" | jq -r '.counts.severity.blocking.present')"
check "  but a second still-unknown check keeps it ungraded" "false" "$(printf '%s' "$r" | jq -r '.ready_to_grade')"

# --- failure modes -----------------------------------------------------------
bash "$S" >/dev/null 2>&1;                     check "no argument exits 2" 2 $?
bash "$S" "$TMP/absent.json" >/dev/null 2>&1;  check "a missing findings file exits 2" 2 $?
bash "$S" "$(w notreport '{"hello":true}')" >/dev/null 2>&1
check "a file that is not an inspect report exits 2" 2 $?
bash "$S" "$RAW" "$TMP/absent.json" >/dev/null 2>&1
check "a missing answers file exits 2" 2 $?
bash "$S" "$RAW" "$(w badjson '{ not json')" >/dev/null 2>&1
check "an unreadable answers file exits 2" 2 $?
bash "$S" "$RAW" "$(w badarr '["a"]')" >/dev/null 2>&1
check "an answers file that is not an object exits 2" 2 $?
bash "$S" "$RAW" "$(w badverdict '{"b-present":"missing"}')" >/dev/null 2>&1
check "a verdict outside present|gap|unknown exits 2" 2 $?

# A stale key warns rather than failing, same as plan-issues.sh, and for the same reason: it is
# harmless on its own and failing would throw away the good answers alongside it.
r="$(bash "$S" "$RAW" "$(w stale '{"b-unknown":"present","ghost":"gap"}')" --json 2>/dev/null)"
check "an answer for a real id is still applied alongside a stale one" 2 \
  "$(printf '%s' "$r" | jq -r '.counts.severity.blocking.present')"
check "  and warns about the stale key" 1 \
  "$(bash "$S" "$RAW" "$TMP/stale.json" --json 2>&1 >/dev/null | grep -c 'ghost')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
