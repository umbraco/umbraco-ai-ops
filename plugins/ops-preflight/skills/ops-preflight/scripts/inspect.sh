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
# EVIDENCE STRENGTH LIVES ON THE PATTERN, NOT ON THE CHECK. Every `any_path` glob and
# `any_file_contains` rule carries a `strength`, `strong` by default: STRONG means the thing
# matched is named for, or dedicated to, the exact job the check is asking about, and a match
# there resolves the check straight to `present` (source: detected), evidence shown, no question.
# WEAK means the match is only generic or keyword evidence — it proves something exists without
# proving it does THIS job (a `package.json` proves a package exists, not that the published
# version lives there; an `azure-pipelines.yml` proves CI exists, not that it publishes a release).
# A weak match reports `unknown` with `source: weak` and keeps its evidence, so the interview can
# open with what was found — the same shape `signal: true` gave a whole check before this existed.
# A check with NO evidence that could ever be strong (a NuGet.config only ever HINTS a restore
# might need a credential; nothing detectable proves it does not) still sets `signal: true` at the
# check level, as shorthand for "every pattern here defaults to weak" rather than writing `weak` on
# each one. Without either of these the check reads PRESENT for exactly the repo most likely to
# fail — found in a dry run, and it is the same false-confidence shape as `ops-install`'s "a signal
# is a hint, not a verdict".
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

# One shared cleanup point for every temp file this script creates. A check's evidence is no
# longer capped (see the per-check loop below), and a real repo can hand jq an evidence array of
# several hundred paths. Passing that as a `--argjson` LITERAL blows the OS argv limit (hit against
# a real repo: "Argument list too long"), so evidence is written to a file instead and read back
# with `--slurpfile`, which only ever puts a short file PATH on the command line. `ev_strong_file`
# and `ev_weak_file` below are two of these, reused (overwritten) once per check rather than one
# temp file per check, so a 26-check run still creates a handful of files, not dozens.
TMPFILES=()
trap 'rm -f "${TMPFILES[@]}"' EXIT

# The stack names ACTIVE for this repo, used only by a `whole_product` check (see checks.schema.json)
# once two or more are active. With zero or one, the whole-product rule is a no-op and this stays
# `[]` unread. Empty under `--checks` (test mode: select-profile.sh never runs, so there is no
# notion of "which stacks are active"; a whole-product check behaves exactly like an ordinary one).
active_stacks_json='[]'

merge_files=()
if [ "${#files[@]}" -eq 0 ]; then
  sel_json="$(bash "$HERE/select-profile.sh" "$repo" --json)" \
    || { echo "ERROR: select-profile.sh failed" >&2; exit 2; }
  base_file="$(printf '%s' "$sel_json" | jq -r '.sources[] | select(.layer=="base") | .path' | tr -d '\r')"
  mapfile -t stack_files < <(printf '%s' "$sel_json" | jq -r '.sources[] | select(.layer=="stack") | .path' | tr -d '\r')
  repo_file="$(printf '%s' "$sel_json" | jq -r '.sources[] | select(.layer=="repo") | .path' | tr -d '\r')"
  [ -n "$base_file" ] || { echo "ERROR: select-profile.sh returned no base layer" >&2; exit 2; }
  active_stacks_json="$(printf '%s' "$sel_json" | jq -c '.summary.stacks')"

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
    TMPFILES+=("$stack_overlay")
    jq -s '
      # A pattern earns an `origin` the moment it is read off ITS OWN profile file, before it ever
      # joins the union below: this is the ONLY place a stack name is ever written onto a pattern.
      # A `whole_product` check (see checks.schema.json) reads it back out later, in inspect.sh
      # proper, to tell "this proves the dotnet half" from "this proves the node half" once the
      # union below has already merged both stacks patterns into one array and thrown that
      # distinction away otherwise.
      def tag_origin(det; origin):
        if det == null then null else
          det
          | .any_path = ((.any_path // []) | map(
              if type == "object" then (. + {origin: origin}) else {glob: ., origin: origin} end
            ))
          | .any_file_contains = ((.any_file_contains // []) | map(. + {origin: origin}))
        end;
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
            ($f.profile // "unknown") as $origin
            | reduce ($f.checks[]) as $c (.;
              (.[$c.id] // {}) as $prev
              | .[$c.id] = (($prev * $c) | .detect = union_detect($prev.detect; tag_origin($c.detect; $origin)))
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

# Reused every iteration (see the TMPFILES comment above) rather than one pair per check.
ev_strong_file="$(mktemp)"; TMPFILES+=("$ev_strong_file")
ev_weak_file="$(mktemp)"; TMPFILES+=("$ev_weak_file")

verdicts='{}'
while IFS= read -r id; do
  [ -n "$id" ] || continue
  # Resolve THIS check's `signal` into an explicit strength on every pattern before detect-lib.sh
  # ever sees it: a bare any_path string stays `strong` unless the check is `signal: true`, in
  # which case it defaults to `weak` instead — the shorthand the schema documents. An any_path
  # object, or an any_file_contains entry, that already names its own `strength` keeps it either
  # way, so one pattern can still be `strong` inside an otherwise-`signal` check.
  d="$(printf '%s' "$merged" | jq -c --arg id "$id" '
    (map(select(.id==$id))[0]) as $c
    | ($c.signal // false) as $sig
    | ($c.detect // null) as $det
    | if $det == null then null else
        $det
        # An any_path entry may already be an object here: the dual-stack union above tags every
        # pattern with its `origin` BEFORE strength is ever resolved, so "already an object" can no
        # longer be read as "already has its strength decided". Default strength on ANY object
        # missing it, the same way any_file_contains already does below, instead of assuming a bare
        # string is the only case that still needs one.
        | .any_path = ((.any_path // []) | map(
            if type == "object" then (. + { strength: (.strength // (if $sig then "weak" else "strong" end)) })
            else { glob: ., strength: (if $sig then "weak" else "strong" end) } end
          ))
        | .any_file_contains = ((.any_file_contains // []) | map(
            . + { strength: (.strength // (if $sig then "weak" else "strong" end)) }
          ))
      end
  ')"
  # Every matched path now carries the STRENGTH it matched at (as before) and the ORIGIN it matched
  # from (new: a stack name when the dual-stack union above tagged it, "base" otherwise). Evidence
  # is split into two lists here, both kept in FULL (no cap), because a `whole_product` check needs
  # to know exactly which origins earned a strong match, and the text report is the only place that
  # ever shortens either list (see the findings build below).
  ev_strong=(); ev_weak=(); has_strong=1; strong_origins=""
  if [ "$d" != "null" ]; then
    raw="$(preflight_detect_ex "$repo" "$d" 2>/dev/null | tr -d '\r')"
    if [ -n "$raw" ]; then
      printf '%s\n' "$raw" | cut -f1 | grep -qx strong && has_strong=0
      strong_paths="$(printf '%s\n' "$raw" | awk -F'\t' '$1=="strong"{print $3}' | sort -u)"
      # The SAME file can legitimately match a strong pattern under one glob and a weak pattern
      # under another on the same check (a post-release-cleanup skill matches both the strong
      # `*post-release*` glob and the weak `*clean*` one). `comm -23` drops it from the weak list
      # once it is already strong evidence, so a row never shows one file twice as if it were two.
      weak_paths="$(comm -23 \
        <(printf '%s\n' "$raw" | awk -F'\t' '$1=="weak"{print $3}' | sort -u) \
        <(printf '%s\n' "$strong_paths" | sort -u) 2>/dev/null)"
      while IFS= read -r line; do [ -n "$line" ] && ev_strong+=("$line"); done <<< "$strong_paths"
      while IFS= read -r line; do [ -n "$line" ] && ev_weak+=("$line"); done <<< "$weak_paths"
      strong_origins="$(printf '%s\n' "$raw" | awk -F'\t' '$1=="strong"{print $2}' | sort -u)"
    fi
  fi

  # THE FIX: a `whole_product` check (verify-build/test/lint-command, verify-warnings-clean, see
  # checks.schema.json) asks about the WHOLE product, so a strong match tagged to only ONE of two-or-
  # more ACTIVE stacks must never resolve it. That is the OR-union `signal: true` was built to stop,
  # returning through pattern strength: a real npm test script is genuinely strong evidence for the
  # node half, and proves nothing about the dotnet half sitting right next to it. A strong match
  # tagged "base" (a literal root build.sh/test.sh/lint.sh) is the one exception: a real repo-wide
  # command genuinely answers the question regardless of how many stacks exist, so it counts for
  # every active stack at once rather than needing to be repeated once per stack.
  whole_product="$(printf '%s' "$merged" | jq -r --arg id "$id" \
    '(map(select(.id==$id))[0].whole_product // false)')"
  active_stack_count="$(printf '%s' "$active_stacks_json" | jq 'length')"
  unaccounted_json='[]'
  if [ "$whole_product" = "true" ] && [ "$has_strong" -eq 0 ] && [ "$active_stack_count" -ge 2 ]; then
    strong_origins_json="$(printf '%s\n' "$strong_origins" | jq -R . | jq -sc 'map(select(length>0))')"
    unaccounted_json="$(jq -nc --argjson active "$active_stacks_json" --argjson strong "$strong_origins_json" '
      if ($strong | index("base")) then [] else ($active - $strong) end
    ')"
  fi
  unaccounted_count="$(printf '%s' "$unaccounted_json" | jq 'length')"

  total_ev=$(( ${#ev_strong[@]} + ${#ev_weak[@]} ))
  if [ "$total_ev" -eq 0 ]; then
    verdict="unknown"; source="null"
  elif [ "$has_strong" -eq 0 ] && [ "$unaccounted_count" -eq 0 ]; then
    verdict="present"; source="detected"    # at least one match named the job directly
  elif [ "$has_strong" -eq 0 ] && [ "$unaccounted_count" -gt 0 ]; then
    verdict="unknown"; source="partial"     # strong for SOME active stacks, not all: not a pass
  else
    verdict="unknown"; source="weak"        # every match was only generic or keyword evidence
  fi
  # Written to a FILE and read back with `--slurpfile`, not handed to jq as a `--argjson` literal:
  # an evidence array is uncapped now, and a real repo's real match count is easily large enough to
  # overflow the OS argv limit as an inline argument (see the TMPFILES comment above).
  printf '%s\n' "${ev_strong[@]+"${ev_strong[@]}"}" | jq -R . | jq -sc 'map(select(length>0))' > "$ev_strong_file"
  printf '%s\n' "${ev_weak[@]+"${ev_weak[@]}"}"   | jq -R . | jq -sc 'map(select(length>0))' > "$ev_weak_file"
  verdicts="$(printf '%s' "$verdicts" | jq -c \
    --arg id "$id" --arg v "$verdict" --arg s "$source" --argjson u "$unaccounted_json" \
    --slurpfile es "$ev_strong_file" --slurpfile ew "$ev_weak_file" \
    '.[$id] = {verdict:$v, source:(if $s=="null" then null else $s end),
               evidence_strong:$es[0], evidence_weak:$ew[0], unaccounted:$u}')"
done < <(printf '%s' "$merged" | jq -r '.[].id' | tr -d '\r')

# The report groups on `section` — the nine headings on the source checklist (AI Ops — Preparing
# your Harness for Automation) — in a FIXED order, not alphabetical and not by `consumer`. Release
# management and Testing come first because they are what unlock the merge and release parts of
# the pipeline; Misc comes last. Within a section, blocking sorts above quality. A `section` this
# map does not recognise sorts after Misc rather than erroring or vanishing from the report.
#
# `evidence` stays a flat, uncapped array for anything still reading it: STRONG matches first, then
# WEAK, each internally sorted. `evidence_more` is purely informational here: it is what the
# TEXT report below hides (weak entries past its own cap), never applied to `evidence` itself. JSON
# never hides a match, strong or weak.
#
# `verdicts` is written to a file and read back with `--slurpfile`, same reason as every other
# per-check write above: by now it holds every check's full evidence, easily large enough to
# overflow the OS argv limit as a `--argjson` literal on a real repo.
verdicts_file="$(mktemp)"; TMPFILES+=("$verdicts_file")
printf '%s' "$verdicts" > "$verdicts_file"
findings="$(printf '%s' "$merged" | jq -c --slurpfile v "$verdicts_file" '
  ($v[0]) as $v
  | def sorder: {"Release management":0,"Testing":1,"Harness":2,"Environment":3,"Frontend":4,
               "Backend":5,"Best practices":6,"Utilities":7,"Misc":8};
  [ .[] | . + ($v[.id] // {verdict:"unknown", source:null, evidence_strong:[], evidence_weak:[], unaccounted:[]})
        | .evidence = (.evidence_strong + .evidence_weak)
        | .evidence_more = (if (.evidence_weak|length) > 3 then (.evidence_weak|length) - 3 else 0 end)
  ]
  | sort_by([ (sorder[.section] // 9), (if .severity=="blocking" then 0 else 1 end), .id ])
')"

# `findings` is read back with `--slurpfile`, same reason as everywhere above: evidence is uncapped
# now, and this is every check's evidence at once.
findings_file="$(mktemp)"; TMPFILES+=("$findings_file")
printf '%s' "$findings" > "$findings_file"
report="$(jq -nc --slurpfile f "$findings_file" --arg repo "$repo" --args '
  ($f[0]) as $f
  | { repo: $repo,
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

# Severity used to be glued onto every row with a comma — "[WEAK   ] Needed for the loops to
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
    # Strong evidence prints first, on its own `found:` line, capped at 3 to stay readable: the whole
    # point is that a reader can see what earned a PRESENT, and 3 examples always suffice. Weak evidence,
    # if any, prints second on its own `also seen (weak):` line so it is never mistaken for what earned
    # the pass, and it is also capped at 3 for readability. A row with no strong evidence at all (an ASK)
    # still gets one plain `found:` line so the interview opens with what was seen. `unaccounted`, when
    # non-empty, names the active stack(s) a `whole_product` check found no strong evidence for: the
    # reason a row that DID match strongly still reads ASK rather than PRESENT.
    printf '%s' "$findings" | jq -r --arg g "$group" --arg s "$sev" '
      .[] | select(.section==$g and .severity==$s)
      | "    [\(if .verdict=="present" then "PRESENT" elif (.source=="weak" or .source=="partial") then "ASK    " else "unknown" end)] " +
        "\(.title) (\(.consumer)\(if (.action // "") != "" then " " + .action else "" end))"
        + ( if (.evidence_strong|length) > 0 then
              "\n              found: " + (.evidence_strong[0:3] | join(", "))
                + (if (.evidence_strong|length) > 3 then " (+\((.evidence_strong|length)-3) more)" else "" end)
            elif (.evidence_weak|length) > 0 then
              "\n              found: " + (.evidence_weak[0:3] | join(", "))
                + (if (.evidence_weak|length) > 3 then " (+\((.evidence_weak|length)-3) more)" else "" end)
            else "" end )
        + ( if (.evidence_strong|length) > 0 and (.evidence_weak|length) > 0 then
              "\n              also seen (weak): " + (.evidence_weak[0:3] | join(", "))
                + (if (.evidence_weak|length) > 3 then " (+\((.evidence_weak|length)-3) more)" else "" end)
            else "" end )
        + ( if (.unaccounted // [] | length) > 0 then
              "\n              no strong evidence from: " + (.unaccounted | join(", "))
            else "" end )
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
