#!/usr/bin/env bash
# Turn the gaps a preflight run found into a plan of GitHub issues.
#
# It PLANS, it does not create — the same split plan-labels.sh makes, and for the same reason.
# Creating is a write against GitHub and goes through `github-ops` -> `create-issue` from the
# skill; keeping the decision here makes it deterministic and testable, and keeping the write
# there keeps auth and the forge mechanism in one place.
#
# Only a `gap` becomes an issue. `unknown` never does: filing work for something nobody has
# looked at is how a backlog fills with noise, and it would quietly convert "we could not see it"
# into "it is missing", which is the exact honesty this tool exists to keep.
#
# TITLES ARE STABLE, derived from the check id. That is what makes a second run safe: the skill
# searches for the title before creating, finds the issue already open, and files nothing. Rename
# a check id and every issue already filed against it is orphaned — so do not.
#
# Usage:
#   plan-issues.sh <findings.json> [answers.json] [--json]
#
# answers.json is a flat map of check id -> present | gap | unknown, written by the skill after
# the interview. Without it there are no gaps, because only a human can declare one.
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
  jq empty "$answers" 2>/dev/null || { echo "ERROR: $answers is not valid JSON" >&2; exit 2; }
  jq -e 'type == "object"' "$answers" >/dev/null 2>&1 \
    || { echo "ERROR: $answers must be an object of check-id -> present|gap|unknown" >&2; exit 2; }
  bad="$(jq -r '[to_entries[] | select((.value | IN("present","gap","unknown")) | not) | .key] | join(", ")' "$answers")"
  [ -z "$bad" ] || { echo "ERROR: $answers has verdicts that are not present|gap|unknown: $bad" >&2; exit 2; }
  ans="$(cat "$answers")"
fi

# An answer for an id that is not in this report almost always means the report was regenerated
# after the interview — the answers are then about a different set of checks. Warn; do not fail,
# because a stale key is harmless on its own and stopping here would lose the good answers.
unknown_keys="$(jq -r --slurpfile f "$findings" '
  ($f[0].findings | map(.id)) as $ids
  | [ keys[] | select(. as $k | $ids | index($k) | not) ] | join(", ")' <<<"$ans")"
[ -z "$unknown_keys" ] || echo "WARN: answers name check(s) this report does not contain: $unknown_keys" >&2

# Sections come out in the same FIXED order inspect.sh's report groups on: release management and
# testing first, since they unlock the merge and release parts of the pipeline, misc last. Within
# a section, blocking sorts above quality — same as the report, so the filed backlog reads in the
# order a repo actually hits the problems.
plan="$(jq -c --argjson a "$ans" '
  def sorder: {"Release management":0,"Testing":1,"Harness":2,"Environment":3,"Frontend":4,
               "Backend":5,"Best practices":6,"Utilities":7,"Misc":8};
  [ .findings[]
    | . + { resolved: ($a[.id] // .verdict) }
    | select(.resolved == "gap")
    | {
        id: .id,
        severity: .severity,
        section: .section,
        consumer: .consumer,
        title: ("ops-preflight: " + .title),
        labels: ["ops/preflight"],
        body: (
          .why
          + "\n\nWhat breaks without it: **" + .consumer
          + (if (.action // "") != "" then " " + .action else "" end) + "**"
          + ": " + (if .severity == "blocking" then
                       "this capability cannot be written until it is true."
                     else
                       "the loops will run, but the work they produce will be worse."
                     end)
          + "\n\nClose this when it is true.\n\n"
          + "_Filed by `ops-preflight` (check `" + .id + "`). The title is stable, so re-running "
          + "the preflight finds this issue and files nothing._"
        )
      } ]
  | sort_by([(sorder[.section] // 9), (if .severity=="blocking" then 0 else 1 end), .id])
' "$findings")"

if [ "$fmt" = "json" ]; then
  printf '%s' "$plan" | jq -c '{
    issues: .,
    summary: {
      total: length,
      blocking: ([.[] | select(.severity=="blocking")] | length),
      quality:  ([.[] | select(.severity=="quality")]  | length),
      label: "ops/preflight"
    }
  }'
  exit 0
fi

n="$(printf '%s' "$plan" | jq 'length')"
if [ "$n" -eq 0 ]; then
  printf 'No gaps to file.\n\n'
  printf '  Nothing here was answered `gap`. Note this is NOT the same as everything passing:\n'
  printf '  a check nobody answered stays `unknown`, and unknown is not a pass.\n'
  exit 0
fi

printf 'Issues to file (%s)\n\n' "$n"
printf '%s' "$plan" | jq -r '.[] | "  \(if .severity=="blocking" then "Needed for the loops to work" else "Makes the loops better" end)  \(.title)"' | tr -d '\r'
printf '\n  %s needed for the loops to work, %s that make the loops better, all labelled ops/preflight\n' \
  "$(printf '%s' "$plan" | jq '[.[] | select(.severity=="blocking")] | length')" \
  "$(printf '%s' "$plan" | jq '[.[] | select(.severity=="quality")] | length')"
printf '\n  Create the ops/preflight label first (github-ops -> create-label, idempotent), then\n'
printf '  each issue with github-ops -> create-issue. SEARCH FOR THE TITLE FIRST: the titles are\n'
printf '  stable so a re-run can skip what is already open, and create-issue is not idempotent.\n'
