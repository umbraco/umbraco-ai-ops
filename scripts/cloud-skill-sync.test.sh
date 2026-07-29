#!/usr/bin/env bash
# Tests for cloud-skill-sync.sh. Hermetic: bash + jq only, no network — $OPS_SRC points at
# this checkout so nothing is cloned, and $OPS_HOME redirects every install into a temp dir.
#
# Usage: bash cloud-skill-sync.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/cloud-skill-sync.sh"
ENGINE="$HERE/.."
[ -f "$SYNC" ] || { echo "FATAL: cloud-skill-sync.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }
ok()    { if [ -e "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — missing $2"; fi; }

run() { OPS_SRC="$1" OPS_HOME="$2" bash "$SYNC" >/dev/null 2>&1; }

# --- a real run against this checkout -------------------------------------
H="$TMP/home"; mkdir -p "$H"
run "$ENGINE" "$H"
check "exits 0" 0 $?

ok "it writes a log"                 "$H/skill-sync.log"
ok "installs github-ops"             "$H/.claude/skills/github-ops/SKILL.md"
ok "installs loop-dispatch"          "$H/.claude/skills/loop-dispatch/SKILL.md"
ok "installs ops-issue-loop"         "$H/.claude/skills/ops-issue-loop/SKILL.md"
ok "installs ops-triage-loop"        "$H/.claude/skills/ops-triage-loop/SKILL.md"
ok "installs a capability skill"     "$H/.claude/skills/ops-integrate/SKILL.md"
ok "installs the installer"          "$H/.claude/skills/ops-install/SKILL.md"
ok "carries a skill's scripts too"   "$H/.claude/skills/loop-dispatch/scripts/route-event.sh"
ok "carries a skill's references"    "$H/.claude/skills/ops-branching/references/gitflow.md"
ok "installs the release-reviewer agent" "$H/.claude/agents/release-reviewer.md"

# Every skill in the repo lands — that is the point of not keeping a list.
want="$(find "$ENGINE/plugins" -mindepth 3 -maxdepth 3 -type d -path '*/skills/*' | wc -l | tr -d ' ')"
got="$(find "$H/.claude/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
check "every skill in the repo is delivered" "$want" "$got"

# --- the capture hooks and their wiring -----------------------------------
ok "installs the capture hook"        "$H/.claude/ops-hooks/hooks/capture-proto-learning.sh"
ok "installs the analyzer prompts"    "$H/.claude/ops-hooks/hooks/analyzer-subagent.md"
ok "installs the schema the hook reads" "$H/.claude/ops-hooks/skills/ops-triage-loop/references/proto-learning-schema.md"
ok "writes settings.json"             "$H/.claude/settings.json"

s="$H/.claude/settings.json"
check "registers SubagentStop"  "1" "$(jq '.hooks.SubagentStop | length' "$s")"
check "registers SessionEnd"    "1" "$(jq '.hooks.SessionEnd | length' "$s")"
check "the hook runs async"     "true" "$(jq -r '.hooks.SubagentStop[0].hooks[0].async' "$s")"
check "SubagentStop uses the subagent scope" "1" \
  "$(jq -r '.hooks.SubagentStop[0].hooks[0].command | test("capture-proto-learning.sh\" subagent$") | if . then 1 else 0 end' "$s")"
check "SessionEnd uses the orchestrator scope" "1" \
  "$(jq -r '.hooks.SessionEnd[0].hooks[0].command | test("capture-proto-learning.sh\" orchestrator$") | if . then 1 else 0 end' "$s")"

# The path it wired must be the path it installed — a hook pointing at nothing is the exact
# failure this test exists to catch.
cmd="$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$s" | sed -e 's/^bash "//' -e 's/" subagent$//')"
ok "the wired hook path exists" "$cmd"

# --- existing settings are preserved --------------------------------------
H2="$TMP/home2"; mkdir -p "$H2/.claude"
printf '{"model":"sonnet","hooks":{"PreToolUse":[{"hooks":[]}]}}\n' > "$H2/.claude/settings.json"
run "$ENGINE" "$H2"
check "keeps an unrelated setting"      "sonnet" "$(jq -r '.model' "$H2/.claude/settings.json")"
check "keeps an unrelated hook"         "1"      "$(jq '.hooks.PreToolUse | length' "$H2/.claude/settings.json")"
check "and still adds SubagentStop"     "1"      "$(jq '.hooks.SubagentStop | length' "$H2/.claude/settings.json")"

# --- an existing hook on the SAME event must survive ----------------------
# This is the case the earlier wiring got wrong: it assigned `.SessionEnd = [ours]`, which
# deleted whatever else the environment had registered on that event, in a file this script does
# not own. The unrelated-event case above passed throughout, so nothing caught it.
H4="$TMP/home4"; mkdir -p "$H4/.claude"
printf '{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"echo theirs"}]}]}}\n' \
  > "$H4/.claude/settings.json"
run "$ENGINE" "$H4"
check "keeps a foreign hook on the same event" "1" \
  "$(jq '[.hooks.SessionEnd[] | select(any(.hooks[]?; .command == "echo theirs"))] | length' "$H4/.claude/settings.json")"
check "  and adds ours alongside it"           "2" \
  "$(jq '.hooks.SessionEnd | length' "$H4/.claude/settings.json")"
run "$ENGINE" "$H4"
check "  and a re-run still does not duplicate" "2" \
  "$(jq '.hooks.SessionEnd | length' "$H4/.claude/settings.json")"

# --- idempotency: running twice must not duplicate the hooks --------------
run "$ENGINE" "$H2"
check "a second run does not duplicate SubagentStop" "1" "$(jq '.hooks.SubagentStop | length' "$H2/.claude/settings.json")"
check "a second run does not duplicate SessionEnd"   "1" "$(jq '.hooks.SessionEnd | length' "$H2/.claude/settings.json")"

# --- a bad source must not fail the environment build ---------------------
H3="$TMP/home3"; mkdir -p "$H3"
OPS_SRC="$TMP/not-a-checkout" OPS_REPO="file:///nonexistent-$$" OPS_HOME="$H3" bash "$SYNC" >/dev/null 2>&1
check "a broken source still exits 0" 0 $?
if grep -q "FATAL: could not clone" "$H3/skill-sync.log"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: a failed clone should say so in the log"; fi

# --- the token path -------------------------------------------------------
# The repo is PRIVATE, so an anonymous clone gets nothing. These assert the token is used and,
# more importantly, that it never reaches the log — a Setup-script log a session can read is
# exactly where a leaked credential would sit unnoticed.
#
# The URL has to start https://github.com/ or the token-splice path is not exercised at all, but
# these tests must not touch the network. So git is pointed at a dead loopback proxy: the clone
# fails instantly, locally, and identically on every machine. Without this the first draft of
# these tests really did clone github, and one case passed only because this developer's OS
# credential helper silently authenticated a private repo.
SECRET="ghp_TESTTOKENdonotuse1234567890"
GITHUB_URL="https://github.com/umbraco/umbraco-ai-ops"
nonet() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://127.0.0.1:1 "$@"; }

H4="$TMP/h4"
nonet env OPS_SRC="$TMP/nope" OPS_REPO="$GITHUB_URL" \
  OPS_TOKEN="$SECRET" OPS_HOME="$H4" bash "$SYNC" >/dev/null 2>&1
check "a token run still exits 0" 0 $?
if grep -q "$SECRET" "$H4/skill-sync.log"; then
  fail=$((fail+1)); echo "FAIL: THE TOKEN LEAKED INTO THE LOG"
else pass=$((pass+1)); fi
if grep -q "using a token for the clone" "$H4/skill-sync.log"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: should say a token was used"; fi
if grep -q "check it can read" "$H4/skill-sync.log"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: a failed token clone should hint at the token, not at being anonymous"; fi

# GH_TOKEN and GITHUB_TOKEN are accepted as fallbacks, because a runner often already has one.
for var in GH_TOKEN GITHUB_TOKEN; do
  H="$TMP/h-$var"
  nonet env "$var=$SECRET" OPS_SRC="$TMP/nope" OPS_REPO="$GITHUB_URL" \
    OPS_HOME="$H" bash "$SYNC" >/dev/null 2>&1
  if grep -q "using a token for the clone" "$H/skill-sync.log"; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $var should be accepted as a token"; fi
  if grep -q "$SECRET" "$H/skill-sync.log"; then
    fail=$((fail+1)); echo "FAIL: $var LEAKED INTO THE LOG"
  else pass=$((pass+1)); fi
done

# No token: still tries, and the hint must name the fix rather than blaming the token.
H5="$TMP/h5"
nonet env OPS_SRC="$TMP/nope" OPS_REPO="$GITHUB_URL" OPS_HOME="$H5" \
  OPS_TOKEN= GH_TOKEN= GITHUB_TOKEN= bash "$SYNC" >/dev/null 2>&1
if grep -q "no token set" "$H5/skill-sync.log"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: should say no token was set"; fi
if grep -q "this repo is private" "$H5/skill-sync.log"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: the no-token hint should explain the repo is private"; fi

# A non-github URL must not have a token spliced into it.
H6="$TMP/h6"
OPS_SRC="$TMP/nope" OPS_REPO="file:///nonexistent-$$" OPS_TOKEN="$SECRET" OPS_HOME="$H6" \
  bash "$SYNC" >/dev/null 2>&1
if grep -q "$SECRET" "$H6/skill-sync.log"; then
  fail=$((fail+1)); echo "FAIL: token leaked on a non-github remote"
else pass=$((pass+1)); fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
