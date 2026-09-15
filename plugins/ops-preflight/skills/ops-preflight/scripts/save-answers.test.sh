#!/usr/bin/env bash
# Tests for save-answers.sh. Hermetic: bash + jq only, nothing filed, no network.
#
# THIS IS THE ONLY THING PREFLIGHT EVER WRITES, so most of what is asserted here is what it must
# NOT do. It must not record a verdict nobody was asked for. It must not carry a pass flag. It must
# not lose the date an answer was given, because an answer about a build command is only as good as
# the day someone said it. And a second run must not flatten the dates of answers it did not touch.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/save-answers.sh"
[ -f "$S" ] || { echo "FATAL: save-answers.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

w() { printf '%s' "$2" > "$TMP/$1"; printf '%s' "$TMP/$1"; }

FIND="$(w findings.json '{
  "repo":"/x","sources":[],
  "findings":[
    {"id":"verify-build-command","consumer":"ops-change","action":"verify","severity":"blocking",
     "section":"Harness","title":"Commands build the whole product","why":"w",
     "ask":"What commands build this product, and in what order?","verdict":"unknown","source":null,"evidence":[]},
    {"id":"release-trigger","consumer":"ops-release","action":"publish","severity":"blocking",
     "section":"Release management","title":"Something publishes","why":"w",
     "ask":"What publishes a release here?","verdict":"unknown","source":null,"evidence":[]},
    {"id":"no-question","consumer":"general","severity":"quality","section":"Misc",
     "title":"Nobody is asked this","why":"w","verdict":"unknown","source":null,"evidence":[]},
    {"id":"never-asked","consumer":"general","severity":"quality","section":"Misc",
     "title":"Asked, but not this time","why":"w","ask":"q?","verdict":"unknown","source":null,"evidence":[]}
  ]}')"

repo() { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }
out()  { cat "$TMP/$1/.claude/ops-preflight-answers.json"; }

# --- the ordinary case ---------------------------------------------------------
R="$(repo one)"
A="$(w a1.json '{"verify-build-command":"present","release-trigger":"gap"}')"
# A real two-stack repo answers this with a LIST, not one command, and the whole list has to
# survive into `said`. Half a build command is how `/ops-install` writes half a capability.
SAID="$(w s1.json '{"verify-build-command":"npm ci && npm run build, then dotnet build Product.slnx"}')"
OPS_PREFLIGHT_TODAY=14-09-2026 bash "$S" "$R" "$FIND" "$A" "$SAID" >/dev/null 2>&1
check "it writes into the repo's .claude folder" 0 "$([ -f "$R/.claude/ops-preflight-answers.json" ]; echo $?)"
check "valid JSON"                    0 "$(out one | jq empty >/dev/null 2>&1; echo $?)"
check "version is pinned"             1 "$(out one | jq '.version')"
check "one entry per question answered" 2 "$(out one | jq '.answers | length')"
check "the whole list is kept, not just the verdict" "npm ci && npm run build, then dotnet build Product.slnx" \
  "$(out one | jq -r '.answers[] | select(.id=="verify-build-command") | .said')"
check "the question is kept verbatim" "What commands build this product, and in what order?" \
  "$(out one | jq -r '.answers[] | select(.id=="verify-build-command") | .question')"
check "the date is carried"           "14-09-2026" \
  "$(out one | jq -r '.answers[] | select(.id=="verify-build-command") | .answered')"

# consumer and action ride along from the check itself. That is what lets ops-install pick the
# answers for the capability it is filling in, with no mapping table to keep in step with the
# catalog: the catalog already knows which capability each check is about.
check "the capability rides along"    "ops-change" \
  "$(out one | jq -r '.answers[] | select(.id=="verify-build-command") | .consumer')"
check "  and the action with it"      "verify" \
  "$(out one | jq -r '.answers[] | select(.id=="verify-build-command") | .action')"
check "a gap is recorded too"         "gap" \
  "$(out one | jq -r '.answers[] | select(.id=="release-trigger") | .verdict')"
check "an answer with no words has no said key" 0 \
  "$(out one | jq '[.answers[] | select(.id=="release-trigger") | has("said")] | map(select(.)) | length')"

# --- what it must NOT record ---------------------------------------------------
check "a check with no question is never recorded" 0 \
  "$(out one | jq '[.answers[] | select(.id=="no-question")] | length')"
check "a question nobody answered this run is not invented" 0 \
  "$(out one | jq '[.answers[] | select(.id=="never-asked")] | length')"
# The rule the whole design rests on: nothing downstream may branch on this file. A pass flag, a
# score, or a "ready" boolean would be the central config this engine deleted, coming back in.
check "no pass flag anywhere in the file" 0 \
  "$(out one | grep -ciE '"(passed|ready|ok|score|grade|complete)"')"

# --- a second run merges, and does not flatten the older dates ------------------
# The failure this guards against is subtle: re-running preflight a month later and having every
# answer silently re-dated to today, so a year-old build command reads as confirmed this morning.
A2="$(w a2.json '{"release-trigger":"present"}')"
OPS_PREFLIGHT_TODAY=20-10-2026 bash "$S" "$R" "$FIND" "$A2" >/dev/null 2>&1
check "still two answers after the merge" 2 "$(out one | jq '.answers | length')"
check "the re-answered one takes the new date" "20-10-2026" \
  "$(out one | jq -r '.answers[] | select(.id=="release-trigger") | .answered')"
check "  and its new verdict"                  "present" \
  "$(out one | jq -r '.answers[] | select(.id=="release-trigger") | .verdict')"
check "an untouched answer keeps its OWN older date" "14-09-2026" \
  "$(out one | jq -r '.answers[] | select(.id=="verify-build-command") | .answered')"
check "  and keeps what was said"  "npm ci && npm run build, then dotnet build Product.slnx" \
  "$(out one | jq -r '.answers[] | select(.id=="verify-build-command") | .said')"
check "answers are sorted by id, so a re-run makes a readable diff" "release-trigger,verify-build-command" \
  "$(out one | jq -r '[.answers[].id] | join(",")')"

# A file in some other shape is warned about and replaced, never appended to as if it were ours.
R2="$(repo two)"; mkdir -p "$R2/.claude"; printf '%s' '{"hello":true}' > "$R2/.claude/ops-preflight-answers.json"
err="$(OPS_PREFLIGHT_TODAY=14-09-2026 bash "$S" "$R2" "$FIND" "$A" 2>&1 >/dev/null)"
check "a file in the wrong shape warns" 1 "$(printf '%s' "$err" | grep -c 'not in the expected shape')"
check "  and is replaced with a good one" 0 "$(out two | jq empty >/dev/null 2>&1; echo $?)"

# --- failure modes ---------------------------------------------------------------
bash "$S" >/dev/null 2>&1;                             check "no arguments exits 2" 2 $?
bash "$S" "$TMP/nope" "$FIND" "$A" >/dev/null 2>&1;    check "a missing repo exits 2" 2 $?
bash "$S" "$(repo three)" "$TMP/nope.json" "$A" >/dev/null 2>&1
check "a missing findings file exits 2" 2 $?
bash "$S" "$(repo four)" "$(w notreport.json '{"hello":true}')" "$A" >/dev/null 2>&1
check "a file that is not an inspect report exits 2" 2 $?
bash "$S" "$(repo five)" "$FIND" "$(w badverdict.json '{"verify-build-command":"maybe"}')" >/dev/null 2>&1
check "a verdict outside present|gap|unknown exits 2" 2 $?
bash "$S" "$(repo six)" "$FIND" "$(w notobj.json '["a"]')" >/dev/null 2>&1
check "an answers file that is not an object exits 2" 2 $?
bash "$S" "$(repo seven)" "$FIND" "$A" "$TMP/nope.json" >/dev/null 2>&1
check "a missing said file exits 2" 2 $?

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
