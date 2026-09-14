#!/usr/bin/env bash
# What is still to ask, in the order to ask it.
#
# WHY THIS EXISTS: there was a script for every step except this one. `inspect.sh` produces the
# findings, `plan-issues.sh` and `score.sh` both need the answers, and the step in between — work
# out which questions are still open and in what order — had nothing. A live run against a large
# repo hand-wrote a Python one-liner three times to get at it, and got the JSON key wrong twice
# (it is `findings`, not `checks`) before it worked. Doing by hand what every neighbouring step has
# a tested script for is how the order drifts from what the skill says.
#
# THE ORDER IS THE SKILL'S ORDER, not the report's:
#
#   1. Must-haves first, all of them, then the nice-to-haves. Somebody who runs out of patience
#      halfway should have answered the ones that decide whether the loops can start at all.
#   2. Within that, the report's fixed section order, release management and testing first.
#   3. Within a section, by id, so two runs of this list the same way.
#
# WHAT IT LEAVES OUT, and each omission is the point:
#
#   A check detection already resolved. Nobody is asked what the files answered.
#   A check with no `ask`. Nobody was ever going to be asked it.
#   A check already answered, when an answers file is given, so a second pass shows only what is
#   left rather than starting again.
#
# Hermetic: bash + jq. Reads, never writes.
#
# Usage:
#   questions.sh <findings.json> [answers.json] [--json]
set -uo pipefail

findings="" answers="" fmt="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) fmt="json"; shift ;;
    -h|--help) echo "usage: $(basename "$0") <findings.json> [answers.json] [--json]"; exit 0 ;;
    *) if [ -z "$findings" ]; then findings="$1"; elif [ -z "$answers" ]; then answers="$1"; fi; shift ;;
  esac
done

[ -n "$findings" ] || { echo "usage: $(basename "$0") <findings.json> [answers.json] [--json]" >&2; exit 2; }
[ -f "$findings" ] || { echo "ERROR: no such file: $findings" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
jq -e '.findings | type == "array"' "$findings" >/dev/null 2>&1 \
  || { echo "ERROR: $findings is not an inspect.sh report (no findings array)" >&2; exit 2; }

ans='{}'
if [ -n "$answers" ]; then
  [ -f "$answers" ] || { echo "ERROR: no such file: $answers" >&2; exit 2; }
  jq -e 'type == "object"' "$answers" >/dev/null 2>&1 \
    || { echo "ERROR: $answers must be an object of check-id -> present|gap|unknown" >&2; exit 2; }
  ans="$(cat "$answers")"
fi

open_json="$(jq -c --argjson a "$ans" '
  def sorder: {"Release management":0,"Testing":1,"Harness":2,"Environment":3,"Frontend":4,
               "Backend":5,"Best practices":6,"Utilities":7,"Misc":8};
  [ .findings[]
    | select((.ask // "") != "")                     # nobody can answer what was never asked
    | select(.verdict != "present")                  # detection already settled it
    | select($a[.id] == null or $a[.id] == "unknown") # already answered, or answered "do not know"
    | { id, section, severity, question: .ask,
        found: ((.evidence_strong // []) + (.evidence_weak // []) | .[0:3]) } ]
  | sort_by([ (if .severity == "blocking" then 0 else 1 end), (sorder[.section] // 9), .id ])
' "$findings")"

if [ "$fmt" = "json" ]; then printf '%s\n' "$open_json"; exit 0; fi

total="$(printf '%s' "$open_json" | jq 'length')"
must="$(printf '%s' "$open_json" | jq '[.[] | select(.severity=="blocking")] | length')"
nice=$((total - must))

if [ "$total" -eq 0 ]; then
  printf 'Nothing left to ask.\n\n'
  printf 'Every check is either answered or was settled by what is in the repo. Run score.sh.\n'
  exit 0
fi

printf 'Still to ask: %s\n\n' "$total"
printf 'Ask the %s must-have question(s) first, four at a time, then stop and offer the other %s.\n' \
  "$must" "$nice"
printf 'Four per call is the question tool limit, not a choice.\n\n'

for sev in blocking quality; do
  n="$(printf '%s' "$open_json" | jq --arg s "$sev" '[.[] | select(.severity==$s)] | length')"
  [ "$n" -gt 0 ] || continue
  if [ "$sev" = blocking ]; then printf 'Needed for the loops to work\n'
  else                           printf 'Makes the loops better\n'; fi
  printf '%s' "$open_json" | jq -r --arg s "$sev" '.[] | select(.severity==$s)
    | "  [\(.section)] \(.id)\n      \(.question)"
      + (if (.found | length) > 0 then "\n      already seen: \(.found | join(", "))" else "" end)'
  printf '\n'
done

printf 'Anything already seen is what to open the question with. A weak match is a starting point,\n'
printf 'never the answer.\n'
