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

if [ "${#files[@]}" -eq 0 ]; then
  mapfile -t files < <(bash "$HERE/select-profile.sh" "$repo" | tr -d '\r')
  [ "${#files[@]}" -gt 0 ] || { echo "ERROR: select-profile.sh returned nothing" >&2; exit 2; }
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
# needs — a profile giving `any_path` means "these instead", never "these as well".
merged="$(jq -s '
  reduce .[] as $f ({}; reduce ($f.checks[]) as $c (.; .[$c.id] = ((.[$c.id] // {}) * $c)))
  | to_entries | map(.value)
' "${files[@]}")" || { echo "ERROR: could not merge the check files" >&2; exit 2; }

# A profile that only ever overrode `detect` can leave a NEW check without the fields the report
# needs. Fail loudly here rather than printing a row with an empty title.
bad="$(printf '%s' "$merged" | jq -r '
  [ .[] | select((.consumer // "") == "" or (.title // "") == "" or (.why // "") == ""
                 or ((.severity // "") | IN("blocking","quality") | not))
        | .id ] | join(", ")')"
[ -z "$bad" ] || { echo "ERROR: incomplete check(s) after merge — need consumer, severity, title, why: $bad" >&2; exit 2; }

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
  ev=()
  if [ "$d" != "null" ]; then
    while IFS= read -r line; do [ -n "$line" ] && ev+=("$line"); done \
      < <(preflight_detect "$repo" "$d" | tr -d '\r' | sort -u | head -3)
  fi
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
    --arg id "$id" --arg v "$verdict" --arg s "$source" --argjson e "$evjson" \
    '.[$id] = {verdict:$v, source:(if $s=="null" then null else $s end), evidence:$e}')"
done < <(printf '%s' "$merged" | jq -r '.[].id' | tr -d '\r')

# The report groups on `consumer`, in the order a repo actually hits the problems: you cannot
# build a change without a workspace, cannot verify one without tests, and cannot release
# anything until both work. Anything unlisted sorts last, alphabetically.
findings="$(printf '%s' "$merged" | jq -c --argjson v "$verdicts" '
  def gorder: {"ops-workspace":0,"ops-change":1,"ops-branching":2,"ops-release":3,"ops-learnings":4,"general":5};
  [ .[] | . + ($v[.id] // {verdict:"unknown", source:null, evidence:[]}) ]
  | sort_by([ (gorder[.consumer] // 9), .consumer, (if .severity=="blocking" then 0 else 1 end), .id ])
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
printf 'ops-preflight — %s\n\n' "$repo"
printf 'Checks from:\n'
for f in "${files[@]}"; do printf '  %s\n' "$f"; done
printf '\n'

while IFS= read -r group; do
  [ -n "$group" ] || continue
  printf '%s\n' "$group"
  printf '%s' "$findings" | jq -r --arg g "$group" '
    .[] | select(.consumer==$g)
    | "  [\(if .verdict=="present" then "PRESENT" elif .source=="signal" then "SIGNAL " else "unknown" end)] \(if .severity=="blocking" then "BLOCKING" else "quality " end)  \(.title)"
      + (if (.evidence|length) > 0 then "\n              found: " + (.evidence | join(", ")) else "" end)
      + (if .verdict=="unknown" then "\n              why:   " + .why else "" end)' | tr -d '\r'
  printf '\n'
  # `findings` is already sorted into group order, so dedupe WITHOUT sorting — `unique` would
  # re-alphabetise the groups and undo the ordering the sort above exists to produce.
done < <(printf '%s' "$findings" | jq -r '.[].consumer' 2>/dev/null | tr -d '\r' | awk '!seen[$0]++')

printf '%s' "$report" | jq -r '.summary
  | "  \(.total) checks — \(.present) present, \(.unknown) unknown (\(.blocking_unknown) of them blocking)"'
printf '\n  UNKNOWN IS NOT A PASS. Detection could not see these; %s of them have a question\n' \
  "$(printf '%s' "$report" | jq -r '.summary.interview')"
printf '  waiting. Answer them, then plan-issues.sh turns whatever is genuinely missing into work.\n'
