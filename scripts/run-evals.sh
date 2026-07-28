#!/usr/bin/env bash
# Run a capability's eval suite. OPT-IN: it needs `claude` and touches a real repo, so it is
# NOT part of the hermetic CI gate and is deliberately not named `*.test.sh`.
#
# What it is for: evals are the only behavioural guard in this engine. `ops-install` can report
# full coverage for a repo whose capabilities are wrong in every action, because coverage
# matches skill NAMES. This is what checks they do the right thing.
#
# How it judges: each case invokes the capability, then a read-only judge scores the transcript
# against that case's asserts, which come from the catalog. LLM-judged, because the thing being
# checked is behaviour described in prose — the alternative is a payload schema, and the spec
# deliberately does not have one.
#
# Usage:
#   run-evals.sh --list                     what suites and cases exist (no model, no repo)
#   run-evals.sh --plan <capability>        print the prompts that would run, and stop
#   run-evals.sh <capability> <repo-root>   run them for real
#
# Env: EVALS_DIR, EVAL_MODEL (default sonnet), EVAL_JUDGE_MODEL (default opus).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
evals="${EVALS_DIR:-$here/../evals}"
model="${EVAL_MODEL:-sonnet}"
judge_model="${EVAL_JUDGE_MODEL:-opus}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }
[ -d "$evals" ] || { echo "ERROR: no eval suites at $evals — run scripts/build-evals.sh" >&2; exit 2; }

# --- --list ---------------------------------------------------------------
if [ "${1:-}" = "--list" ]; then
  found=0
  for f in "$evals"/*.eval.json; do
    [ -f "$f" ] || continue
    found=1
    jq -r '"\(.skill)  (\(.kind), \(.visibility), " + (if .framework_default then "has a default" else "always the repo'"'"'s" end) + ")",
           (.cases[] | "    \(.id)")' "$f"
  done
  [ "$found" = 1 ] || { echo "ERROR: no suites found in $evals" >&2; exit 2; }
  exit 0
fi

plan_only=0
if [ "${1:-}" = "--plan" ]; then plan_only=1; shift; fi

cap="${1:-}"
repo="${2:-}"
[ -n "$cap" ] || { echo "usage: $(basename "$0") [--list | --plan <capability> | <capability> <repo-root>]" >&2; exit 2; }
suite="$evals/$cap.eval.json"
[ -f "$suite" ] || { echo "ERROR: no suite for '$cap' at $suite" >&2; exit 2; }

if [ "$plan_only" = 0 ]; then
  [ -n "$repo" ] || { echo "ERROR: a repo root is required to actually run evals" >&2; exit 2; }
  [ -d "$repo" ] || { echo "ERROR: no such directory: $repo" >&2; exit 2; }
  command -v claude >/dev/null 2>&1 || { echo "ERROR: run-evals needs \`claude\` on PATH. This is opt-in and not part of CI." >&2; exit 2; }
fi

skill="$(jq -r '.skill' "$suite" | tr -d '\r')"
ncases="$(jq '.cases | length' "$suite" | tr -d '\r')"
printf 'Eval: %s — %s case(s)\n' "$skill" "$ncases"

pass=0 fail=0 skipped=0
i=0
while [ "$i" -lt "$ncases" ]; do
  c="$(jq -c ".cases[$i]" "$suite")"
  id="$(printf '%s' "$c" | jq -r '.id')"
  action="$(printf '%s' "$c" | jq -r '.action')"
  ctx="$(printf '%s' "$c" | jq -c '.context')"
  repeat="$(printf '%s' "$c" | jq -r '.repeat // 1')"
  asserts="$(printf '%s' "$c" | jq -r '.asserts | to_entries | map("  \(.key + 1). \(.value)") | join("\n")')"
  i=$((i + 1))

  invoke="Invoke the skill named \`$skill\` with action \`$action\` and this context, exactly as a framework loop would: $ctx"
  [ "$repeat" -gt 1 ] && invoke="$invoke

Do it $repeat times in a row, with the SAME context each time. Report what each invocation returned."

  prompt="$invoke

Report the full result of each invocation verbatim. Do not summarise it, and do not fix or work around anything that goes wrong — this is an observation, not a repair."

  judge_prompt="You are judging one eval case for the capability skill \`$skill\`, action \`$action\`.

The case: $id
The context it was given: $ctx

What must hold:
$asserts

Below is what happened. Judge ONLY against the points above — not against your own view of what the capability should do. Be strict: if something cannot be determined from the evidence, that is not a pass.

End your reply with exactly one line: \`VERDICT: PASS\` or \`VERDICT: FAIL — <one line why>\`."

  if [ "$plan_only" = 1 ]; then
    printf '\n--- %s ---\n%s\n\n[judge]\n%s\n' "$id" "$prompt" "$judge_prompt"
    skipped=$((skipped + 1))
    continue
  fi

  out="$(cd "$repo" && claude -p "$prompt" --model "$model" 2>&1)" || out="INVOCATION FAILED: $out"
  verdict="$(claude -p "$judge_prompt

--- what happened ---
$out" --model "$judge_model" --allowedTools "" 2>&1 | grep -E '^VERDICT:' | tail -1)"

  case "$verdict" in
    "VERDICT: PASS") pass=$((pass + 1)); printf '  PASS  %s\n' "$id" ;;
    VERDICT:*)       fail=$((fail + 1)); printf '  FAIL  %s — %s\n' "$id" "${verdict#VERDICT: FAIL — }" ;;
    *)               fail=$((fail + 1)); printf '  FAIL  %s — the judge returned no verdict\n' "$id" ;;
  esac
done

if [ "$plan_only" = 1 ]; then
  printf '\n%d case(s) planned, none run.\n' "$skipped"
  exit 0
fi
printf '\n%s: %d passed, %d failed\n' "$skill" "$pass" "$fail"
[ "$fail" -eq 0 ]
