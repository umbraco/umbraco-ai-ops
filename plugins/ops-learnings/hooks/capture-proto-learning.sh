#!/usr/bin/env bash
#
# Async proto-learning capture. Ported from the umbraco-mcp-ops prototype and made
# repo-agnostic: the destination repo, the label and the loop signature are all resolved
# rather than hard-coded.
#
#   $1 = scope: "subagent" (SubagentStop) | "orchestrator" (SessionEnd)
#
# Reads the hook event JSON from stdin, finds the transcript, and — only if it belongs to an
# ops loop run — asks a read-only analyzer whether anything worth improving happened. If so,
# files ONE proto-learning issue. The analyzer has no write tools; this script does the
# deterministic issue creation.
#
# IT MUST NEVER FAIL THE SESSION. Every path exits 0. Capture is off the critical path by
# design: a broken analyzer, a missing token or a rate limit must cost a log line, never a
# build. That is why there is no `set -e` here and why every failure logs and exits 0.
#
# WHERE THE ISSUE GOES. The `learnings` role from ops-repo-meta, which defaults to the code
# repo. The hook runs in bash with no session, so it cannot invoke a skill: the consumer sets
# $OPS_LEARNINGS_REPO in .claude/settings.json when its learnings repo is not the current one.
# Unset means the current repo, which is what the framework default resolves to anyway.
#
# Env knobs (ops + test):
#   OPS_LEARNINGS_REPO         owner/name to file into (default: the current git remote)
#   OPS_LEARNINGS_LABEL        the label (default: ops/proto-learning)
#   OPS_LEARNINGS_SIGNATURE    grep -E pattern that marks a transcript as an ops loop run
#   OPS_LEARNINGS_DRY_RUN=1    log the intended issue instead of filing it (no gh, no network)
#   OPS_LEARNINGS_ANALYZER_OUT inject a canned analyzer decision (skips `claude`)
#   OPS_LEARNINGS_LOG          override the log file path
#   OPS_LEARNINGS_STATE        override the marker directory
#   OPS_LEARNINGS_CAPTURE=1    re-entry guard (set internally; never set by hand)
set -uo pipefail

SCOPE="${1:-subagent}"
LABEL="${OPS_LEARNINGS_LABEL:-ops/proto-learning}"
# EVERY framework loop, or capture is silently blind to whichever ones are missing. The list
# started at three and the port and merge loops were added to the engine without it, so their
# runs produced no lessons at all and nothing said so. If a loop is added, add it here.
SIGNATURE="${OPS_LEARNINGS_SIGNATURE:-ops-issue-loop|ops-rework-loop|ops-port-loop|ops-merge-loop|ops-release-loop|ops-triage-loop|ops/ready-for-ai}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCHEMA="$PLUGIN_ROOT/skills/ops-triage-loop/references/proto-learning-schema.md"
LOG="${OPS_LEARNINGS_LOG:-${HOME}/.cache/ops-learnings/capture.log}"
STATE="${OPS_LEARNINGS_STATE:-$(dirname "$LOG")}"
mkdir -p "$(dirname "$LOG")" "$STATE" 2>/dev/null || true
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ 2>/dev/null || echo now)" "$SCOPE" "$*" >>"$LOG" 2>/dev/null || true; }

# Everything this hook writes to stderr goes to the log as well. A hook runs async and detached,
# so its stderr otherwise goes nowhere: when the prompt build failed, the log recorded the
# downstream symptom and threw the line saying why on the floor. A log that keeps symptoms and
# discards causes is worse than no log, because it reads as though it were complete.
exec 2>>"$LOG"

# --- Re-entry guard --------------------------------------------------------
# The analyzer below is itself a `claude` session that loads this plugin, so its own
# SessionEnd/SubagentStop would re-invoke this script. The env var is inherited by that child
# and its hooks, so they exit here instead of recursing forever.
if [ -n "${OPS_LEARNINGS_CAPTURE:-}" ]; then exit 0; fi
export OPS_LEARNINGS_CAPTURE=1

command -v jq >/dev/null 2>&1 || { log "missing jq — skipping capture"; exit 0; }

EVENT="$(cat)"
TRANSCRIPT="$(printf '%s' "$EVENT" | jq -r '.transcript_path // empty' 2>/dev/null)"
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  log "no readable transcript_path — skipping"; exit 0
fi

# --- Cheap pre-filter: only act on ops loop runs ---------------------------
# Avoids spawning an analyzer for every unrelated subagent in the session.
if ! grep -qiE "$SIGNATURE" "$TRANSCRIPT" 2>/dev/null; then
  log "transcript has no loop signature — skipping"; exit 0
fi

# --- Once-per-session guard ------------------------------------------------
# transcript_path is the WHOLE shared session JSONL, not a per-subagent slice. Resuming a
# stuck subagent fires another SubagentStop over the same (growing) transcript, so without
# this the same session gets re-analysed repeatedly. Analyse each session once per scope.
#
# The marker is CLAIMED just before the analyzer is spawned and RELEASED if the spawn or the
# analyzer fails, so a crashed analyzer can still be retried. It used to be written after the
# analyzer returned, which left the whole analyzer run unclaimed: fine while that run was
# synchronous and short, wrong now the analyzer is detached and can be in flight for minutes
# while another SubagentStop fires on the same session.
SID="$(printf '%s' "$EVENT" | jq -r '.session_id // empty' 2>/dev/null)"
MARKER=""
if [ -n "$SID" ]; then
  MARKER="$STATE/analyzed-$SCOPE-$SID"
  if [ -f "$MARKER" ]; then log "session $SID ($SCOPE) already analysed — skipping"; exit 0; fi
fi

PROMPT_FILE="$PLUGIN_ROOT/hooks/analyzer-$SCOPE.md"
[ -f "$PROMPT_FILE" ] || { log "no prompt file $PROMPT_FILE — skipping"; exit 0; }

# --- Resolve the destination repo -----------------------------------------
REPO="${OPS_LEARNINGS_REPO:-}"
if [ -z "$REPO" ]; then
  origin="$(git config --get remote.origin.url 2>/dev/null || true)"
  # One expression, shared verbatim with detect.sh and plan-labels.sh — see detect.sh for the
  # order. A stray trailing slash here would send the issue to `owner/name/`, which 404s.
  REPO="$(printf '%s' "$origin" | sed -E 's#^ssh://##; s#^https?://##; s#^[^@/]*@##; s#^[^/:]+:##; s#^[^/]*\.[^/]*/##; s#/+$##; s#\.git$##')"
fi
if [ -z "$REPO" ]; then log "no destination repo (set \$OPS_LEARNINGS_REPO) — skipping"; exit 0; fi

# --- Analyze (read-only) ---------------------------------------------------
# Substitute with bash, NOT sed. A transcript path on Windows is `C:\Users\...\D--Repo\4d62...`,
# and sed treats a backslash in the REPLACEMENT as an escape: `\4` is a backreference to a group
# that does not exist, so sed aborts with "invalid reference \4 on `s' command's RHS", prints
# nothing, and `$(...)` yields an empty prompt. `claude -p ""` then refuses with "Input must be
# provided...", which was the only error ever reaching the log, because sed's own stderr was not
# captured. Capture ran that way for seven weeks: ~2250 failures against 3 filings, the 3 being
# the runs whose path happened to have no digit after a backslash.
#
# `${var//find/replace}` does no escape processing at all, so any path survives it verbatim.
TEMPLATE="$(cat "$PROMPT_FILE")" || { log "could not read $PROMPT_FILE — skipping"; exit 0; }
PROMPT="${TEMPLATE//\{\{TRANSCRIPT\}\}/$TRANSCRIPT}"
PROMPT="${PROMPT//\{\{SCHEMA\}\}/$SCHEMA}"
PROMPT="${PROMPT//\{\{REPO\}\}/$REPO}"

# An empty prompt is the failure the comment above is about. Catch it HERE, where the reason is
# knowable, rather than letting `claude` report it downstream as its own usage error.
[ -n "$PROMPT" ] || { log "prompt came out empty from $PROMPT_FILE — skipping"; exit 0; }

# Size, every run. Had this line existed, the log would have read "prompt built: 0 bytes" on
# day one instead of an unexplained refusal from `claude` three steps later.
log "prompt built: ${#PROMPT} bytes"

# --- What happens to the analyzer's answer ---------------------------------
# A function, because there are now two callers: the test seam below, which runs inline, and
# the detached analyzer further down. `return`, never `exit` — an `exit` here would kill the
# subshell mid-flight and skip the marker release.
record() {
  OUT="$1"

  # The analyzer outputs a single JSON object, optionally fenced. Strip fences.
  JSON="$(printf '%s' "$OUT" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//' | jq -c . 2>/dev/null)"
  if [ -z "$JSON" ]; then
    log "analyzer output not JSON: $(printf '%s' "$OUT" | tr -d '\n' | head -c 200)"; return 0
  fi

  if [ "$(printf '%s' "$JSON" | jq -r '.file // false')" != "true" ]; then
    log "analyzer decided not to file — nothing captured"; return 0
  fi

  TITLE="$(printf '%s' "$JSON" | jq -r '.title // empty')"
  [ -n "$TITLE" ] || { log "analyzer said file:true with no title — skipping"; return 0; }

  RECORD="$(printf '%s' "$JSON" | jq -r '.record // {} | tojson')"
  NOTES="$(printf '%s' "$JSON" | jq -r '.notes // ""')"
  BODY="$(printf '```json\n%s\n```\n\n**Notes:** %s\n' "$RECORD" "$NOTES")"

  if [ -n "${OPS_LEARNINGS_DRY_RUN:-}" ]; then
    log "DRY RUN would file to $REPO [$LABEL]: $TITLE"
    log "DRY RUN body: $(printf '%s' "$BODY" | tr -d '\n' | head -c 300)"
    return 0
  fi

  # --- File it -------------------------------------------------------------
  # `gh` locally; on a runner without it, curl + the REST API. Dedupe on an exact open title
  # either way — deeper clustering is ops-triage-loop's job, not the analyzer's.
  API="https://api.github.com/repos/$REPO/issues"
  TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

  if command -v gh >/dev/null 2>&1; then
    if gh issue list --repo "$REPO" --label "$LABEL" --state open --search "$TITLE" \
         --json title --jq '.[].title' 2>/dev/null | grep -qxF "$TITLE"; then
      log "duplicate open proto-learning, skipping: $TITLE"; return 0
    fi
    if URL="$(gh issue create --repo "$REPO" --label "$LABEL" --title "$TITLE" --body "$BODY" 2>>"$LOG")"; then
      log "filed proto-learning: $URL"
    else
      log "gh issue create failed for: $TITLE"
    fi
  elif [ -n "$TOKEN" ] && command -v curl >/dev/null 2>&1; then
    gh_api() { curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
                    -H "X-GitHub-Api-Version: 2022-11-28" "$@" 2>>"$LOG"; }
    if gh_api "$API?state=open&labels=$LABEL&per_page=100" | jq -r '.[].title' 2>/dev/null | grep -qxF "$TITLE"; then
      log "duplicate open proto-learning, skipping: $TITLE"; return 0
    fi
    payload="$(jq -nc --arg t "$TITLE" --arg b "$BODY" --arg l "$LABEL" '{title:$t,body:$b,labels:[$l]}')"
    # Capture status + body so a failure (e.g. a 403 from an auth/scope problem) is logged
    # rather than swallowed — an empty .html_url used to hide the real reason.
    resp="$(gh_api -w $'\n%{http_code}' -X POST "$API" -d "$payload")"
    http="$(printf '%s' "$resp" | tail -n1)"
    body="$(printf '%s' "$resp" | sed '$d')"
    URL="$(printf '%s' "$body" | jq -r '.html_url // empty' 2>/dev/null)"
    if [ "$http" = "201" ] && [ -n "$URL" ]; then
      log "filed proto-learning (rest api): $URL"
    else
      log "REST issue create failed (HTTP ${http:-?}) for: $TITLE — $(printf '%s' "$body" | tr -d '\n' | head -c 300)"
    fi
  else
    log "no gh and no token — skipping capture"
  fi
  return 0
}

# Give the session back so a failed analyzer can be retried on the next fire.
release_marker() { [ -n "$MARKER" ] && rm -f "$MARKER" 2>/dev/null; return 0; }

log "analyzing $TRANSCRIPT"

# Claim the session now, before anything long-running starts. See the once-per-session guard.
[ -n "$MARKER" ] && { : >"$MARKER" 2>/dev/null || true; }

# Test seam: a canned analyzer response, recorded inline. Deliberately BEFORE the detach — the
# tests assert on log lines, and a detached writer would race them.
if [ -n "${OPS_LEARNINGS_ANALYZER_OUT:-}" ]; then
  record "$OPS_LEARNINGS_ANALYZER_OUT"
  exit 0
fi

# Nothing was spawned, so give the session back rather than retiring it over a missing binary.
command -v claude >/dev/null 2>&1 || { log "missing claude — skipping capture"; release_marker; exit 0; }

# --- Isolate the analyzer from the invoking session ------------------------
# The analyzer is a nested `claude`, and a child inherits the variables that bind a process to
# THIS session's inbound message channel: the runner's messaging socket and token, the session
# ingress token file, and the session ids. With those inherited the analyzer joins the very
# loop session it is analyzing, so a live event meant for the loop — a CI webhook, or the
# loop's own self-scheduled check-in — can be delivered into the analyzer's turn and never
# reach the loop's driving logic. On the prototype that starved a loop's check-in and stalled a
# release mid-flight (hifi-phil/umbraco-mcp-ops#93).
#
# Drop them, so the analyzer can only ever run as its own unaddressable session. CLAUDE_PID is
# in the list because the socket path is derived from it. The OAuth token is deliberately NOT
# dropped: that is what AUTHENTICATES the analyzer, not what ADDRESSES it, and capture without
# it does nothing at all.
#
# OPS_LEARNINGS_CAPTURE stays exported too. It is the re-entry guard, and the analyzer is
# itself a session whose own SessionEnd would otherwise re-invoke this script.
ISOLATE=(env
  -u CLAUDE_CODE_MESSAGING_SOCKET
  -u CLAUDE_CODE_MESSAGING_TOKEN
  -u CLAUDE_SESSION_INGRESS_TOKEN_FILE
  -u CLAUDE_CODE_POST_FOR_SESSION_INGRESS_V2
  -u CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR
  -u CLAUDE_CODE_REMOTE_SESSION_ID
  -u CLAUDE_CODE_SESSION_ID
  -u CLAUDE_PID
)

# Bound the runtime where the tool exists. Detached and disowned, nothing on the loop's side
# supervises the analyzer any more, so a hang would otherwise hold the marker claimed and the
# analyzer's auth alive indefinitely.
if command -v timeout >/dev/null 2>&1; then ISOLATE=(timeout 600 "${ISOLATE[@]}"); fi

# A new process session too, where the tool exists. The hook fires as the loop session is
# ending, so staying in its process group means the analyzer is torn down with it. Detached, it
# outlives that teardown. Without `setsid` (macOS) the analyzer stays in the hook's process
# group and loses that immunity, but is still env-isolated from the loop's live events — which
# is the part that corrupts a running loop.
if command -v setsid >/dev/null 2>&1; then ISOLATE=(setsid "${ISOLATE[@]}"); fi

# Run detached and return immediately, so nothing on the loop's side — not even this already
# async hook process — has the analyzer in front of it.
(
  # `env -u` removes the variable's NAME from the child's environment; it does not close the
  # descriptor that variable names. If this fd was inherited without O_CLOEXEC the analyzer
  # could still read and write the loop session's websocket auth channel despite never seeing
  # the name. Close it directly.
  case "${CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR:-}" in
    ''|*[!0-9]*) : ;;
    *) eval "exec ${CLAUDE_CODE_WEBSOCKET_AUTH_FILE_DESCRIPTOR}<&-" 2>/dev/null || true ;;
  esac
  OUT="$("${ISOLATE[@]}" claude -p "$PROMPT" --model sonnet --allowedTools "Read,Grep" 2>>"$LOG")" \
    || {
      # Release BEFORE logging, so the log line is the signal that cleanup has finished rather
      # than that it is about to start. Nothing outside this detached subshell can see it
      # otherwise, so the order is what the tests can key on.
      release_marker; log "analyzer invocation failed"; exit 0;
    }
  record "$OUT"
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
