#!/usr/bin/env bash
# Write down what a person told the preflight interview, so nobody has to say it twice.
#
# WHY THIS EXISTS: preflight asks "what single command builds this whole product?" and a person
# answers it. Then `/ops-install` scaffolds an `ops-change` stub and asks the same thing again,
# because nothing carried the answer across. That is three or four repeated questions per repo, and
# the person answering has no way to know it is the same question.
#
# WHAT IT IS NOT, and this matters more than what it is:
#
#   NOT a "preflight passed" flag. Nothing routes on this file. No loop reads it. `ops-install`
#   behaves identically whether it exists or not; it only offers the answers back. A flag something
#   later branches on is the central config this design deleted, arriving by the back door.
#
#   NOT a fact. It is a record of what someone SAID, on a date, which the schema makes you carry.
#   An answer about a build command is only as good as the day it was given, so `ops-install` shows
#   the date alongside it and a person confirms before anything is written from it.
#
#   NOT the report, and not the score. Those still persist nowhere: they would be stale the moment
#   somebody fixed something, and a stale report read as current is worse than no report.
#
# `consumer` and `action` ride along from the check itself, so `ops-install` can pick out the
# answers for the capability it is filling in without a mapping table that has to be kept in step
# with the catalog. The catalog already knows which capability each check is about.
#
# A re-run MERGES: an answer given today replaces the one with the same id and leaves every other
# answer, and its own older date, alone.
#
# Hermetic: bash + jq. Writes exactly one file, and only into the repo it was pointed at.
#
# Usage:
#   save-answers.sh <repo-root> <findings.json> <answers.json> [said.json]
#
#   findings.json  what inspect.sh --json produced: supplies the question text, consumer and action
#   answers.json   flat map of check id -> present|gap|unknown, the same file plan-issues.sh reads
#   said.json      optional, flat map of check id -> what the person actually said, in their words
set -uo pipefail

repo="" findings="" answers="" said=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) echo "usage: $(basename "$0") <repo-root> <findings.json> <answers.json> [said.json]"; exit 0 ;;
    *) if   [ -z "$repo" ];     then repo="$1"
       elif [ -z "$findings" ]; then findings="$1"
       elif [ -z "$answers" ];  then answers="$1"
       elif [ -z "$said" ];     then said="$1"; fi; shift ;;
  esac
done

[ -n "$repo" ] && [ -n "$findings" ] && [ -n "$answers" ] \
  || { echo "usage: $(basename "$0") <repo-root> <findings.json> <answers.json> [said.json]" >&2; exit 2; }
[ -d "$repo" ] || { echo "ERROR: no such directory: $repo" >&2; exit 2; }
[ -f "$findings" ] || { echo "ERROR: no such file: $findings" >&2; exit 2; }
[ -f "$answers" ]  || { echo "ERROR: no such file: $answers" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

jq -e '.findings | type == "array"' "$findings" >/dev/null 2>&1 \
  || { echo "ERROR: $findings is not an inspect.sh report (no findings array)" >&2; exit 2; }
jq -e 'type == "object"' "$answers" >/dev/null 2>&1 \
  || { echo "ERROR: $answers must be an object of check-id -> present|gap|unknown" >&2; exit 2; }
bad="$(jq -r '[to_entries[] | select((.value | IN("present","gap","unknown")) | not) | .key] | join(", ")' "$answers")"
[ -z "$bad" ] || { echo "ERROR: $answers has verdicts that are not present|gap|unknown: $bad" >&2; exit 2; }

said_json='{}'
if [ -n "$said" ]; then
  [ -f "$said" ] || { echo "ERROR: no such file: $said" >&2; exit 2; }
  jq -e 'type == "object"' "$said" >/dev/null 2>&1 \
    || { echo "ERROR: $said must be an object of check-id -> what the person said" >&2; exit 2; }
  said_json="$(cat "$said")"
fi

out="$repo/.claude/ops-preflight-answers.json"
mkdir -p "$repo/.claude" || { echo "ERROR: could not create $repo/.claude" >&2; exit 2; }

# An existing file is merged into, never replaced. `OPS_PREFLIGHT_TODAY` exists so the test can pin
# the date; nothing else should set it.
today="${OPS_PREFLIGHT_TODAY:-$(date +%d-%m-%Y)}"
existing='{"version":1,"answers":[]}'
if [ -f "$out" ]; then
  if jq -e '.answers | type == "array"' "$out" >/dev/null 2>&1; then
    existing="$(cat "$out")"
  else
    echo "WARN: $out is not in the expected shape; starting a fresh one" >&2
  fi
fi

# `--slurpfile` wants a real file and is handed one for the two big inputs. The existing file is
# already in a variable, so it goes in as `--argjson`: process substitution is not a file on every
# platform this runs on, and jq reports that as "Bad JSON" rather than as the missing file it is.
merged="$(jq -n \
  --slurpfile f "$findings" --slurpfile a "$answers" \
  --argjson existing "$existing" --argjson said "$said_json" --arg today "$today" '
  ($f[0].findings) as $findings
  | ($a[0]) as $given
  | ($existing.answers // []) as $before
  # One entry per question a person answered NOW. A check with no `ask` is skipped: nobody was
  # asked, so there is nothing anyone said to record.
  | [ $findings[]
      | select($given[.id] != null)
      | select((.ask // "") != "")
      | { id, consumer, action, question: .ask, verdict: $given[.id],
          said: ($said[.id] // ""), answered: $today }
      | if (.said == "") then del(.said) else . end
      | if (.action == null) then del(.action) else . end
      | if (.consumer == null) then del(.consumer) else . end
    ] as $now
  | ($now | map(.id)) as $fresh
  # Today wins for anything answered today; everything else keeps its entry AND its own older date.
  | { version: 1,
      answers: (($before | map(select(.id as $i | $fresh | index($i) | not))) + $now)
               | sort_by(.id) }
')" || { echo "ERROR: could not build the answers file" >&2; exit 2; }

printf '%s\n' "$merged" | jq . > "$out" || { echo "ERROR: could not write $out" >&2; exit 2; }

n_now="$(printf '%s' "$merged" | jq --arg d "$today" '[.answers[] | select(.answered == $d)] | length')"
n_all="$(printf '%s' "$merged" | jq '.answers | length')"
printf 'Wrote %s\n' "${out#"$repo"/}"
printf '  %s answer(s) from today, %s in total.\n' "$n_now" "$n_all"
printf '  ops-install offers these back while it fills in a capability. Nothing routes on this\n'
printf '  file, and every answer shows the date it was given.\n'
