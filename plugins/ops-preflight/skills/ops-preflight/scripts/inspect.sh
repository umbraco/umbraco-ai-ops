#!/usr/bin/env bash
# Run every check that applies to a repo, and report what the files can and cannot answer.
#
# IT NEVER RUNS YOUR BUILD. It reads files. That is a deliberate limit, not an oversight: a
# preflight that compiles the product only works on a machine that can compile the product, which
# rules out CI, a routine, and anyone looking at a repo they do not work on. Hermetic — bash + jq.
#
# THREE VERDICTS, NEVER TWO:
#
#   present   detection matched (source: detected), or a human confirmed it (source: declared)
#   gap       a human said it is not there — only ever set by the interview, never by this script
#   unknown   detection found nothing and nobody has been asked
#
# Silence is never a pass. A check with no `detect` block, or one whose globs miss, comes back
# `unknown` and stays there until a human resolves it. This is the same rule as "a gate that
# cannot run reports blocked": an unrunnable check reports unknown, not a pass.
#
# A check marked `signal: true` INVERTS what a match means: finding the file is a reason to ASK,
# never a pass. A NuGet.config proves a private feed might need a credential; it proves nothing
# about whether a restore works without one. Such a check reports `unknown` with `source: signal`
# and keeps its evidence, so the interview can open with what was found. Without this the check
# reads PRESENT for exactly the repos most likely to fail — found in a dry run, and it is the same
# false-confidence shape as `ops-install`'s "a signal is a hint, not a verdict".
#
# Usage:
#   inspect.sh <repo-root> [--json] [--checks <file>]...
#
# --checks replaces layer selection entirely and is for tests; normally select-profile.sh decides.
set -uo pipefail

repo="" fmt="text"; files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json)   fmt="json"; shift ;;
    --checks) files+=("${2:-}"); shift 2 ;;
    -h|--help) echo "usage: $(basename "$0") <repo-root> [--json] [--checks <file>]..."; exit 0 ;;
    *) [ -z "$repo" ] && repo="$1"; shift ;;
  esac
done

[ -n "$repo" ] || { echo "usage: $(basename "$0") <repo-root> [--json] [--checks <file>]..." >&2; exit 2; }
[ -d "$repo" ] || { echo "ERROR: no such directory: $repo" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=detect-lib.sh
. "$HERE/detect-lib.sh"
repo="$(cd "$repo" && pwd)"

merge_files=()
if [ "${#files[@]}" -eq 0 ]; then
  sel_json="$(bash "$HERE/select-profile.sh" "$repo" --json)" \
    || { echo "ERROR: select-profile.sh failed" >&2; exit 2; }
  base_file="$(printf '%s' "$sel_json" | jq -r '.sources[] | select(.layer=="base") | .path' | tr -d '\r')"
  mapfile -t stack_files < <(printf '%s' "$sel_json" | jq -r '.sources[] | select(.layer=="stack") | .path' | tr -d '\r')
  repo_file="$(printf '%s' "$sel_json" | jq -r '.sources[] | select(.layer=="repo") | .path' | tr -d '\r')"
  [ -n "$base_file" ] || { echo "ERROR: select-profile.sh returned no base layer" >&2; exit 2; }

  # `files` stays the REAL shipped paths — every matching profile individually — so validation
  # errors and the printed "Checks from:" list still name the file a human can go look at.
  files=("$base_file" "${stack_files[@]+"${stack_files[@]}"}")
  [ -n "$repo_file" ] && files+=("$repo_file")

  merge_files=("$base_file")
  if [ "${#stack_files[@]}" -gt 1 ]; then
    # Two or more STACK profiles can match one repo — a repo with a solution and a package.json
    # genuinely has both stacks. select-profile.sh's own promise is that stacks are ADDITIVE
    # ("nothing picks one winner"), but the sequential merge below is later-wins BY FIELD, so
    # feeding these in one at a time would let the second stack silently erase the first stack's
    # `detect` for any check id both override — exactly the dual-stack bug this guards against.
    # Pre-combine the stack layer into ONE synthetic file that UNIONS `detect` across stack peers
    # before it ever reaches the sequential merge, so that merge still only ever sees one entry
    # per layer and its existing base<-override replace contract (tested below) is untouched.
    stack_overlay="$(mktemp)"
    trap 'rm -f "$stack_overlay"' EXIT
    jq -s '
      def union_detect(a; b):
        if a == null then b
        elif b == null then a
        else
          (((a.any_path // []) + (b.any_path // [])) | unique) as $ap
          | (((a.any_file_contains // []) + (b.any_file_contains // [])) | unique) as $afc
          | ( {} + (if ($ap|length) > 0 then {any_path: $ap} else {} end)
                 + (if ($afc|length) > 0 then {any_file_contains: $afc} else {} end) )
        end;
      { version: 1,
        checks: (
          reduce .[] as $f ({};
            reduce ($f.checks[]) as $c (.;
              (.[$c.id] // {}) as $prev
              | .[$c.id] = (($prev * $c) | .detect = union_detect($prev.detect; $c.detect))
            )
          ) | to_entries | map(.value)
        ) }
    ' "${stack_files[@]}" > "$stack_overlay" \
      || { echo "ERROR: could not combine the matching stack profiles" >&2; exit 2; }
    merge_files+=("$stack_overlay")
  elif [ "${#stack_files[@]}" -eq 1 ]; then
    merge_files+=("${stack_files[@]}")
  fi
  [ -n "$repo_file" ] && merge_files+=("$repo_file")
else
  merge_files=("${files[@]}")
fi
for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "ERROR: no such check file: $f" >&2; exit 2; }
  jq empty "$f" 2>/dev/null || { echo "ERROR: $f is not valid JSON" >&2; exit 2; }
  jq -e '(.checks | type) == "array" and (.checks | length) > 0' "$f" >/dev/null 2>&1 \
    || { echo "ERROR: $f has no checks array" >&2; exit 2; }
  dupes="$(jq -r '[.checks[].id] | group_by(.) | map(select(length>1) | .[0]) | join(", ")' "$f")"
  [ -z "$dupes" ] || { echo "ERROR: $f repeats check id(s): $dupes" >&2; exit 2; }
done

# --- merge the layers ------------------------------------------------------------------------
# Later wins BY FIELD, not by whole entry: `*` is jq's recursive merge, so a stack profile can
# carry nothing but an `id` and the `detect` it is replacing and still inherit the base's title,
# why and severity. Arrays replace rather than concatenate, which is what a `detect` override
# needs — a profile giving `any_path` means "these instead", never "these as well". This is why
# the layer that actually feeds the merge is `merge_files`, not `files`: two matching STACK
# profiles are peers, not an override chain, and were already unioned into one synthetic entry
# above so this step only ever sees one file per layer.
merged="$(jq -s '
  reduce .[] as $f ({}; reduce ($f.checks[]) as $c (.; .[$c.id] = ((.[$c.id] // {}) * $c)))
  | to_entries | map(.value)
' "${merge_files[@]}")" || { echo "ERROR: could not merge the check files" >&2; exit 2; }

# A profile that only ever overrode `detect` can leave a NEW check without the fields the report
# needs. Fail loudly here rather than printing a row with an empty title. `section` is one of
# these now too: the report groups on it, so a check that arrives without one would silently drop
# out of every section rather than just rendering blank.
bad="$(printf '%s' "$merged" | jq -r '
  [ .[] | select((.consumer // "") == "" or (.title // "") == "" or (.why // "") == ""
                 or (.section // "") == ""
                 or ((.severity // "") | IN("blocking","quality") | not))
        | .id ] | join(", ")')"
[ -z "$bad" ] || { echo "ERROR: incomplete check(s) after merge — need consumer, severity, title, why, section: $bad" >&2; exit 2; }

# A `signal` check can never resolve itself: a match means ask, and a miss means unknown, so
# without an `ask` there is no path to any verdict but unknown, ever.
nosig="$(printf '%s' "$merged" | jq -r '[ .[] | select((.signal // false) and ((.ask // "") == "")) | .id ] | join(", ")')"
[ -z "$nosig" ] || { echo "ERROR: signal check(s) with no \`ask\` — nothing could ever resolve them: $nosig" >&2; exit 2; }

# --- evaluate --------------------------------------------------------------------------------
preflight_scan "$repo"

verdicts='{}'
while IFS= read -r id; do
  [ -n "$id" ] || continue
  d="$(printf '%s' "$merged" | jq -c --arg id "$id" 'map(select(.id==$id))[0].detect // null')"
  ev=(); ev_total=0
  if [ "$d" != "null" ]; then
    all_ev="$(preflight_detect "$repo" "$d" | tr -d '\r' | sort -u)"
    if [ -n "$all_ev" ]; then
      ev_total="$(printf '%s\n' "$all_ev" | grep -c .)"
      while IFS= read -r line; do [ -n "$line" ] && ev+=("$line"); done \
        < <(printf '%s\n' "$all_ev" | head -3)
    fi
  fi
  # Evidence is capped at 3 paths in the report — plenty to answer "is this real", too many buries
  # the row on a check that legitimately matches dozens of files. The count beyond the cap still
  # matters (three package artifacts and three real test files both print as three), so it rides
  # along as `evidence_more` and the text report renders it as "(+N more)" rather than dropping it
  # silently, which read as "that's everything" when it was not.
  ev_more=$(( ev_total > 3 ? ev_total - 3 : 0 ))
  sig="$(printf '%s' "$merged" | jq -r --arg id "$id" 'map(select(.id==$id))[0].signal // false')"
  if [ "${#ev[@]}" -eq 0 ]; then
    verdict="unknown"; source="null"
  elif [ "$sig" = "true" ]; then
    verdict="unknown"; source="signal"      # a match here means ASK, never pass
  else
    verdict="present"; source="detected"
  fi
  evjson="$(printf '%s\n' "${ev[@]+"${ev[@]}"}" | jq -R . | jq -sc 'map(select(length>0))')"
  verdicts="$(printf '%s' "$verdicts" | jq -c \
    --arg id "$id" --arg v "$verdict" --arg s "$source" --argjson e "$evjson" --argjson m "$ev_more" \
    '.[$id] = {verdict:$v, source:(if $s=="null" then null else $s end), evidence:$e, evidence_more:$m}')"
done < <(printf '%s' "$merged" | jq -r '.[].id' | tr -d '\r')

# The report groups on `section` — the nine headings on the source checklist (AI Ops — Preparing
# your Harness for Automation) — in a FIXED order, not alphabetical and not by `consumer`. Release
# management and Testing come first because they are what unlock the merge and release parts of
# the pipeline; Misc comes last. Within a section, blocking sorts above quality. A `section` this
# map does not recognise sorts after Misc rather than erroring or vanishing from the report.
findings="$(printf '%s' "$merged" | jq -c --argjson v "$verdicts" '
  def sorder: {"Release management":0,"Testing":1,"Harness":2,"Environment":3,"Frontend":4,
               "Backend":5,"Best practices":6,"Utilities":7,"Misc":8};
  [ .[] | . + ($v[.id] // {verdict:"unknown", source:null, evidence:[], evidence_more:0}) ]
  | sort_by([ (sorder[.section] // 9), (if .severity=="blocking" then 0 else 1 end), .id ])
')"

report="$(jq -nc --argjson f "$findings" --arg repo "$repo" --args '
  { repo: $repo,
    sources: $ARGS.positional,
    findings: $f,
    summary: {
      total:            ($f | length),
      present:          ([$f[] | select(.verdict=="present")] | length),
      unknown:          ([$f[] | select(.verdict=="unknown")] | length),
      blocking_unknown: ([$f[] | select(.verdict=="unknown" and .severity=="blocking")] | length),
      interview:        ([$f[] | select(.verdict=="unknown" and (.ask // "") != "")] | length)
    } }' "${files[@]}")"

if [ "$fmt" = "json" ]; then printf '%s\n' "$report"; exit 0; fi

# --- text report ------------------------------------------------------------------------------
printf 'ops-preflight: %s\n\n' "$repo"
printf 'This is a map, not an entry exam, and nobody clears every box.\n'
printf 'Release management and Testing come first below. If you only have time for one section,\n'
printf 'do that one: they are what unlock the merge and release parts of the pipeline.\n\n'
printf 'Checks from:\n'
for f in "${files[@]}"; do printf '  %s\n' "$f"; done
printf '\n'

# Severity used to be glued onto every row with a comma — "[SIGNAL ] Needed for the loops to
# work, Title (consumer)" — which reads as one broken sentence, and repeating the same long label
# on every one of 26 rows was the actual problem, not just the comma. It is printed ONCE per
# section as a sub-heading instead, so it reads as a label over a group rather than a clause welded
# onto each title. `findings` is already sorted blocking-before-quality within a section (see the
# `sort_by` above), so a plain loop over the two severities in that order reproduces it exactly.
while IFS= read -r group; do
  [ -n "$group" ] || continue
  printf '%s\n' "$group"
  for sev in blocking quality; do
    n="$(printf '%s' "$findings" | jq --arg g "$group" --arg s "$sev" \
      '[ .[] | select(.section==$g and .severity==$s) ] | length')"
    [ "$n" -gt 0 ] || continue
    if [ "$sev" = blocking ]; then printf '  Needed for the loops to work\n'
    else                            printf '  Makes the loops better\n'
    fi
    printf '%s' "$findings" | jq -r --arg g "$group" --arg s "$sev" '
      .[] | select(.section==$g and .severity==$s)
      | "    [\(if .verdict=="present" then "PRESENT" elif .source=="signal" then "SIGNAL " else "unknown" end)] " +
        "\(.title) (\(.consumer)\(if (.action // "") != "" then " " + .action else "" end))"
        + (if (.evidence|length) > 0 then "\n              found: " + (.evidence | join(", "))
             + (if (.evidence_more // 0) > 0 then " (+\(.evidence_more) more)" else "" end)
           else "" end)
        + (if .verdict=="unknown" then "\n              why:   " + .why else "" end)' | tr -d '\r'
  done
  printf '\n'
  # `findings` is already sorted into section order, so dedupe WITHOUT sorting — `unique` would
  # re-alphabetise the sections and undo the fixed ordering the sort above exists to produce.
done < <(printf '%s' "$findings" | jq -r '.[].section' 2>/dev/null | tr -d '\r' | awk '!seen[$0]++')

# One jq call, one printf: the closing message used to be split across three separate printf
# statements with a hand-wrapped line break in the middle of a sentence. Building the whole block
# as one string and printing it once removes any chance of a partial write landing between them.
printf '%s' "$report" | jq -r '
  .summary
  | "  \(.total) checks: \(.present) present, \(.unknown) unknown (\(.blocking_unknown) needed for the loops to work)"
  + "\n\n  UNKNOWN IS NOT A PASS. Detection could not see these; \(.interview) of them have a question"
  + "\n  waiting. Answer them, then plan-issues.sh turns whatever is genuinely missing into work."
' | tr -d '\r'
