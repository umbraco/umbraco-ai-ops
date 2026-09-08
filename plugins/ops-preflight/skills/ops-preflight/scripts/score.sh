#!/usr/bin/env bash
# Turn a repo's post-interview preflight findings into a grade, but only once there is nothing
# left to guess at.
#
# THE ONE RULE THIS FILE EXISTS TO ENFORCE: a score is only honest AFTER the interview. A raw
# inspect.sh scan of a live repo can come back mostly `unknown`, detection could not see it, which
# is not a pass and not a fail either. Scoring that scan would hand a well-prepared repo an F for
# having files this tool cannot read. So:
#
#   ANY check still `unknown` -> no grade, no percentage. Print what is known, and say how many
#   checks are still unanswered. Refuse, do not guess.
#
#   EVERY check `present` or `gap` -> grade it.
#
# Same input convention as plan-issues.sh, which this sits next to: it reads the findings.json
# inspect.sh --json produced and the answers.json the interview wrote (a flat map of check id to
# present|gap|unknown), and resolves each check the same way plan-issues.sh does: an answer
# overrides the detected verdict, and a check nobody answered keeps whatever inspect.sh gave it.
#
# WEIGHTED, because a blocking check and a quality check are not worth the same thing: blocking
# carries weight 3, quality weight 1. The score is the weight of the PRESENT checks over the
# weight of every check. A hard cap sits on top of that: if any blocking check is a `gap`, the
# grade cannot read better than C, however good the rest of the repo looks. Something the loops
# need is missing, and no amount of quality polish should paper over that.
#
# Usage:
#   score.sh <findings.json> [answers.json] [--json]
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

# Same stale-key warning as plan-issues.sh, for the same reason: an answer naming a check this
# report does not contain almost always means the report was regenerated after the interview.
# Harmless on its own; warn, do not fail, so the good answers are not thrown away with it.
unknown_keys="$(jq -r --slurpfile f "$findings" '
  ($f[0].findings | map(.id)) as $ids
  | [ keys[] | select(. as $k | $ids | index($k) | not) ] | join(", ")' <<<"$ans")"
[ -z "$unknown_keys" ] || echo "WARN: answers name check(s) this report does not contain: $unknown_keys" >&2

repo="$(jq -r '.repo' "$findings")"

# --- resolve every check, the same way plan-issues.sh does -----------------------------------
# resolved = the human's answer if there is one, else whatever inspect.sh found. A check nobody
# has been asked about, and that detection could not see either, stays `unknown` here too.
resolved="$(jq -c --argjson a "$ans" '[ .findings[] | . + { resolved: ($a[.id] // .verdict) } ]' "$findings")"

total="$(printf '%s' "$resolved" | jq 'length')"
unknown_n="$(printf '%s' "$resolved" | jq '[.[] | select(.resolved=="unknown")] | length')"
ready="$([ "$unknown_n" -eq 0 ] && echo true || echo false)"

# --- counts per severity, then per section, in inspect.sh's fixed section order ---------------
# This is computed the same way whether or not a grade can be printed: "7 of 10 present" is true
# on its own, unknowns included in the denominator, and is exactly the "counts that are known"
# the refusal message has to show.
counts="$(printf '%s' "$resolved" | jq -c '
  def sorder: {"Release management":0,"Testing":1,"Harness":2,"Environment":3,"Frontend":4,
               "Backend":5,"Best practices":6,"Utilities":7,"Misc":8};
  . as $all
  | ($all | map(.section) | unique | sort_by(sorder[.] // 9)) as $secs
  | {
      severity: {
        blocking: { present: ([$all[] | select(.severity=="blocking" and .resolved=="present")] | length),
                    total:   ([$all[] | select(.severity=="blocking")] | length) },
        quality:  { present: ([$all[] | select(.severity=="quality"  and .resolved=="present")] | length),
                    total:   ([$all[] | select(.severity=="quality")]  | length) }
      },
      sections: [ $secs[] as $s | {
        section: $s,
        blocking: { present: ([$all[] | select(.section==$s and .severity=="blocking" and .resolved=="present")] | length),
                    total:   ([$all[] | select(.section==$s and .severity=="blocking")] | length) },
        quality:  { present: ([$all[] | select(.section==$s and .severity=="quality"  and .resolved=="present")] | length),
                    total:   ([$all[] | select(.section==$s and .severity=="quality")]  | length) }
      } ]
    }
' )"

# --- can the loops start at all -----------------------------------------------------------
# Independent of whether a grade can be printed: a blocking check that is not PRESENT, whether
# that is a gap or still unknown, is one the loops cannot rely on yet.
blockers="$(printf '%s' "$resolved" | jq -c '[ .[] | select(.severity=="blocking" and .resolved!="present") | {id: .id, title: .title} ]')"
blockers_n="$(printf '%s' "$blockers" | jq 'length')"
loops_can_start="$([ "$blockers_n" -eq 0 ] && echo true || echo false)"

# --- the grade itself, only when nothing is left unknown --------------------------------------
# blocking weighs 3, quality weighs 1, a must-have outweighs a nice-to-have. The score is the
# weight of what is PRESENT over the weight of everything. The hard cap comes after: any blocking
# `gap` pulls a better-than-C grade down to C, never the other way round.
grade='null'
if [ "$ready" = true ]; then
  grade="$(printf '%s' "$resolved" | jq -c '
    def weight(sev): if sev=="blocking" then 3 else 1 end;
    def band(pct):
      if pct >= 95 then "A*"
      elif pct >= 85 then "A"
      elif pct >= 75 then "B"
      elif pct >= 65 then "C"
      elif pct >= 55 then "D"
      elif pct >= 45 then "E"
      else "F" end;
    def rank(g): {"A*":0,"A":1,"B":2,"C":3,"D":4,"E":5,"F":6}[g];
    ( [ .[] | weight(.severity) ] | add // 0 ) as $tw
    | ( [ .[] | select(.resolved=="present") | weight(.severity) ] | add // 0 ) as $pw
    | ( if $tw > 0 then ($pw / $tw * 100) else 0 end ) as $pct
    | band($pct) as $g
    | ( [ .[] | select(.severity=="blocking" and .resolved=="gap") ] | length > 0 ) as $blocking_gap
    | ( if $blocking_gap and (rank($g) < rank("C")) then "C" else $g end ) as $final
    | { letter: $final, percent: ($pct | round), capped: ($final != $g) }
  ')"
fi

if [ "$fmt" = "json" ]; then
  jq -nc --arg repo "$repo" --argjson total "$total" --argjson unknown "$unknown_n" \
    --argjson ready "$ready" --argjson grade "$grade" --argjson counts "$counts" \
    --argjson loops_can_start "$loops_can_start" --argjson blockers "$blockers" '
    { repo: $repo,
      total_checks: $total,
      unknown_count: $unknown,
      ready_to_grade: $ready,
      grade: $grade,
      counts: $counts,
      loops_can_start: $loops_can_start,
      blocking_not_present: $blockers }'
  exit 0
fi

# --- text report --------------------------------------------------------------------------
printf 'ops-preflight score: %s\n\n' "$repo"
printf 'This is a map, not an entry exam, and nobody clears every box. The grade below is a\n'
printf 'snapshot of the repo as it stands, never a judgement on the people who built it.\n\n'

if [ "$ready" = false ]; then
  printf 'No grade yet.\n\n'
else
  letter="$(printf '%s' "$grade" | jq -r '.letter')"
  percent="$(printf '%s' "$grade" | jq -r '.percent')"
  capped="$(printf '%s' "$grade" | jq -r '.capped')"
  if [ "$capped" = true ]; then
    printf 'Grade: %s (capped). Weighted score %s%%.\n' "$letter" "$percent"
    printf 'A check needed for the loops to work is a gap, so the grade cannot read better than\n'
    printf 'C, however good the rest of the repo looks.\n'
  else
    printf 'Grade: %s (%s%%)\n' "$letter" "$percent"
  fi
  printf '\n'
fi

printf 'Needed for the loops to work: %s of %s present\n' \
  "$(printf '%s' "$counts" | jq -r '.severity.blocking.present')" \
  "$(printf '%s' "$counts" | jq -r '.severity.blocking.total')"
printf 'Makes the loops better: %s of %s present\n\n' \
  "$(printf '%s' "$counts" | jq -r '.severity.quality.present')" \
  "$(printf '%s' "$counts" | jq -r '.severity.quality.total')"

printf '%s' "$counts" | jq -r '
  .sections[] | "\(.section)"
  + (if .blocking.total > 0 then "\n  Needed for the loops to work: \(.blocking.present) of \(.blocking.total) present" else "" end)
  + (if .quality.total  > 0 then "\n  Makes the loops better: \(.quality.present) of \(.quality.total) present" else "" end)
' | tr -d '\r'
printf '\n'

if [ "$ready" = false ]; then
  if [ "$unknown_n" -eq 1 ]; then
    printf '1 check is still unknown. Finish the interview (step 3 in the ops-preflight\n'
  else
    printf '%s checks are still unknown. Finish the interview (step 3 in the ops-preflight\n' "$unknown_n"
  fi
  printf 'skill), then run this again for a grade.\n\n'
fi

if [ "$loops_can_start" = true ]; then
  printf 'Loops can start: yes.\n'
else
  if [ "$blockers_n" -eq 1 ]; then
    check_word="check"
    is_word="is"
  else
    check_word="checks"
    is_word="are"
  fi

  if [ "$blockers_n" -le 2 ]; then
    names="$(printf '%s' "$blockers" | jq -r '[.[].title] | join(", ")')"
    printf 'Loops can start: no. %s %s needed for the loops to work %s not present yet: %s\n' \
      "$blockers_n" "$check_word" "$is_word" "$names"
  else
    printf 'Loops can start: no. %s %s needed for the loops to work %s not present yet:\n' \
      "$blockers_n" "$check_word" "$is_word"
    printf '%s' "$blockers" | jq -r '.[] | "  \(.title)"'
    printf '\n'
  fi
fi
