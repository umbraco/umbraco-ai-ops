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
# this the same session gets re-analysed repeatedly. Analyse each session once per scope; the
# marker is written after the analyzer runs, so a crashed analyzer can be retried.
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
PROMPT="$(sed -e "s#{{TRANSCRIPT}}#$TRANSCRIPT#g" \
              -e "s#{{SCHEMA}}#$SCHEMA#g" \
              -e "s#{{REPO}}#$REPO#g" "$PROMPT_FILE")"

log "analyzing $TRANSCRIPT"
if [ -n "${OPS_LEARNINGS_ANALYZER_OUT:-}" ]; then
  OUT="$OPS_LEARNINGS_ANALYZER_OUT"
else
  command -v claude >/dev/null 2>&1 || { log "missing claude — skipping capture"; exit 0; }
  OUT="$(claude -p "$PROMPT" --model sonnet --allowedTools "Read,Grep" 2>>"$LOG")" || {
    log "analyzer invocation failed"; exit 0; }
fi

[ -n "$MARKER" ] && { : >"$MARKER" 2>/dev/null || true; }

# The analyzer outputs a single JSON object, optionally fenced. Strip fences.
JSON="$(printf '%s' "$OUT" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//' | jq -c . 2>/dev/null)"
if [ -z "$JSON" ]; then
  log "analyzer output not JSON: $(printf '%s' "$OUT" | tr -d '\n' | head -c 200)"; exit 0
fi

if [ "$(printf '%s' "$JSON" | jq -r '.file // false')" != "true" ]; then
  log "analyzer decided not to file — nothing captured"; exit 0
fi

TITLE="$(printf '%s' "$JSON" | jq -r '.title // empty')"
[ -n "$TITLE" ] || { log "analyzer said file:true with no title — skipping"; exit 0; }

RECORD="$(printf '%s' "$JSON" | jq -r '.record // {} | tojson')"
NOTES="$(printf '%s' "$JSON" | jq -r '.notes // ""')"
BODY="$(printf '```json\n%s\n```\n\n**Notes:** %s\n' "$RECORD" "$NOTES")"

if [ -n "${OPS_LEARNINGS_DRY_RUN:-}" ]; then
  log "DRY RUN would file to $REPO [$LABEL]: $TITLE"
  log "DRY RUN body: $(printf '%s' "$BODY" | tr -d '\n' | head -c 300)"
  exit 0
fi

# --- File it -------------------------------------------------------------
# `gh` locally; on a runner without it, curl + the REST API. Dedupe on an exact open title
# either way — deeper clustering is ops-triage-loop's job, not the analyzer's.
API="https://api.github.com/repos/$REPO/issues"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if command -v gh >/dev/null 2>&1; then
  if gh issue list --repo "$REPO" --label "$LABEL" --state open --search "$TITLE" \
       --json title --jq '.[].title' 2>/dev/null | grep -qxF "$TITLE"; then
    log "duplicate open proto-learning, skipping: $TITLE"; exit 0
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
    log "duplicate open proto-learning, skipping: $TITLE"; exit 0
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
exit 0
