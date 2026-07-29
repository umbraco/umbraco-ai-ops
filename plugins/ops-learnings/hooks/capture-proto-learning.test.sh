#!/usr/bin/env bash
# Tests for capture-proto-learning.sh. Hermetic: bash + jq only. No network, no gh, no
# claude — the analyzer is injected via $OPS_LEARNINGS_ANALYZER_OUT and filing is forced
# into dry-run, so nothing ever reaches GitHub.
#
# The property most worth testing is that capture NEVER fails the session: every case
# asserts exit 0, including the broken ones.
#
# Usage: bash capture-proto-learning.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAP="$HERE/capture-proto-learning.sh"
[ -f "$CAP" ] || { echo "FATAL: capture-proto-learning.sh not found at $CAP"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() { # check <name> <want> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi
}
grep_log() { # grep_log <name> <pattern> <want-count>
  local n; n="$(grep -c "$2" "$LOGF" 2>/dev/null || true)"
  check "$1" "$3" "$n"
}

# A transcript that looks like an ops loop run, and one that doesn't.
LOOPY="$TMP/loop.jsonl";  printf '{"m":"running ops-issue-loop for ops/ready-for-ai #4211"}\n' > "$LOOPY"
PLAIN="$TMP/plain.jsonl"; printf '{"m":"just some unrelated session"}\n' > "$PLAIN"

event() { # event <transcript> [session-id]
  jq -nc --arg t "$1" --arg s "${2:-sess-1}" '{transcript_path:$t, session_id:$s}'
}

# run <name> <analyzer-out> <event-json> [extra env assignments...]
run() {
  local name="$1" out="$2" ev="$3"; shift 3
  LOGF="$TMP/log-$name.txt"; STATED="$TMP/state-$name"; mkdir -p "$STATED"
  printf '%s' "$ev" | env \
    OPS_LEARNINGS_LOG="$LOGF" \
    OPS_LEARNINGS_STATE="$STATED" \
    OPS_LEARNINGS_DRY_RUN=1 \
    OPS_LEARNINGS_REPO="owner/repo" \
    OPS_LEARNINGS_ANALYZER_OUT="$out" \
    "$@" bash "$CAP" subagent >/dev/null 2>&1
  check "$name exits 0" 0 $?
}

FILEABLE='{"file":true,"title":"[proto-learning] owner/repo#4211: culture is not honoured in validation","record":{"sourceRepo":"owner/repo","sourceIssue":4211,"category":"pattern-gap","lesson":"State the culture rule in the build skill."},"notes":"came up twice"}'

# --- the happy path --------------------------------------------------------
run "files a learning" "$FILEABLE" "$(event "$LOOPY")"
grep_log "  logs the dry-run filing" "DRY RUN would file to owner/repo \[ops/proto-learning\]" 1
grep_log "  keeps the analyzer's title" "culture is not honoured in validation" 1

# --- the analyzer declining -----------------------------------------------
run "declines quietly" '{"file":false}' "$(event "$LOOPY")"
grep_log "  logs the decision not to file" "decided not to file" 1
grep_log "  files nothing" "DRY RUN would file" 0

# --- fenced output --------------------------------------------------------
run "unwraps fenced json" '```json
{"file":true,"title":"[proto-learning] fenced","record":{}}
```' "$(event "$LOOPY")"
grep_log "  still files" "DRY RUN would file" 1

# --- EVERY framework loop must be recognised ------------------------------
# The default signature listed three loops while the engine shipped six, so port-loop and
# merge-loop runs were skipped and nothing reported it. A loop absent from this list captures
# no lessons at all, which is invisible: the log line reads like a normal non-loop session.
for l in ops-issue-loop ops-rework-loop ops-port-loop ops-merge-loop ops-release-loop ops-triage-loop; do
  t="$TMP/tr-$l.jsonl"; printf '{"m":"running %s for #4211"}\n' "$l" > "$t"
  run "recognises $l" "$FILEABLE" "$(event "$t" "sess-$l")"
  grep_log "  and captures from it" "DRY RUN would file" 1
done

# --- transcripts it must ignore -------------------------------------------
run "ignores a non-loop transcript" "$FILEABLE" "$(event "$PLAIN")"
grep_log "  logs the signature miss" "no loop signature" 1
grep_log "  files nothing" "DRY RUN would file" 0

run "ignores a missing transcript" "$FILEABLE" "$(event "$TMP/nope.jsonl")"
grep_log "  logs the missing transcript" "no readable transcript_path" 1

run "ignores an empty event" "$FILEABLE" '{}'
grep_log "  logs the missing transcript" "no readable transcript_path" 1

# --- malformed analyzer output --------------------------------------------
run "survives non-JSON analyzer output" "I could not decide, sorry." "$(event "$LOOPY")"
grep_log "  logs it as not JSON" "analyzer output not JSON" 1
grep_log "  files nothing" "DRY RUN would file" 0

run "survives file:true with no title" '{"file":true,"record":{}}' "$(event "$LOOPY")"
grep_log "  logs the missing title" "no title" 1
grep_log "  files nothing" "DRY RUN would file" 0

# --- the re-entry guard ---------------------------------------------------
LOGF="$TMP/log-reentry.txt"
printf '%s' "$(event "$LOOPY")" | env OPS_LEARNINGS_CAPTURE=1 OPS_LEARNINGS_LOG="$LOGF" \
  OPS_LEARNINGS_DRY_RUN=1 OPS_LEARNINGS_ANALYZER_OUT="$FILEABLE" bash "$CAP" subagent >/dev/null 2>&1
check "the re-entry guard exits 0" 0 $?
check "the re-entry guard writes no log" 0 "$( [ -f "$LOGF" ] && wc -l < "$LOGF" | tr -d ' ' || echo 0)"

# --- the once-per-session marker ------------------------------------------
LOGF="$TMP/log-once.txt"; STATED="$TMP/state-once"; mkdir -p "$STATED"
for i in 1 2; do
  printf '%s' "$(event "$LOOPY" sess-once)" | env \
    OPS_LEARNINGS_LOG="$LOGF" OPS_LEARNINGS_STATE="$STATED" OPS_LEARNINGS_DRY_RUN=1 \
    OPS_LEARNINGS_REPO="owner/repo" OPS_LEARNINGS_ANALYZER_OUT="$FILEABLE" \
    bash "$CAP" subagent >/dev/null 2>&1
done
grep_log "a session is analysed once, not twice" "DRY RUN would file" 1
grep_log "  the second call says so" "already analysed" 1

# A different scope over the same session is a separate analysis.
LOGF="$TMP/log-scope.txt"; STATED="$TMP/state-scope"; mkdir -p "$STATED"
for s in subagent orchestrator; do
  printf '%s' "$(event "$LOOPY" sess-scope)" | env \
    OPS_LEARNINGS_LOG="$LOGF" OPS_LEARNINGS_STATE="$STATED" OPS_LEARNINGS_DRY_RUN=1 \
    OPS_LEARNINGS_REPO="owner/repo" OPS_LEARNINGS_ANALYZER_OUT="$FILEABLE" \
    bash "$CAP" "$s" >/dev/null 2>&1
done
grep_log "each scope analyses the session once" "DRY RUN would file" 2

# --- the label and repo are configurable ----------------------------------
LOGF="$TMP/log-cfg.txt"; STATED="$TMP/state-cfg"; mkdir -p "$STATED"
printf '%s' "$(event "$LOOPY" sess-cfg)" | env \
  OPS_LEARNINGS_LOG="$LOGF" OPS_LEARNINGS_STATE="$STATED" OPS_LEARNINGS_DRY_RUN=1 \
  OPS_LEARNINGS_REPO="other/inbox" OPS_LEARNINGS_LABEL="ops/pl" \
  OPS_LEARNINGS_ANALYZER_OUT="$FILEABLE" bash "$CAP" subagent >/dev/null 2>&1
grep_log "honours \$OPS_LEARNINGS_REPO and _LABEL" "would file to other/inbox \[ops/pl\]" 1

# --- a custom signature ---------------------------------------------------
LOGF="$TMP/log-sig.txt"; STATED="$TMP/state-sig"; mkdir -p "$STATED"
printf '%s' "$(event "$PLAIN" sess-sig)" | env \
  OPS_LEARNINGS_LOG="$LOGF" OPS_LEARNINGS_STATE="$STATED" OPS_LEARNINGS_DRY_RUN=1 \
  OPS_LEARNINGS_REPO="owner/repo" OPS_LEARNINGS_SIGNATURE="unrelated session" \
  OPS_LEARNINGS_ANALYZER_OUT="$FILEABLE" bash "$CAP" subagent >/dev/null 2>&1
grep_log "honours a custom \$OPS_LEARNINGS_SIGNATURE" "DRY RUN would file" 1

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
