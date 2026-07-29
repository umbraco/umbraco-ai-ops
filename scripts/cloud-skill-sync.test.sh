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

# --- the clone is anonymous -----------------------------------------------
# The engine is PUBLIC, so there is no token path left to test. What is worth asserting is the
# absence: no credential splicing in the code, and no hint sending a human after a variable that
# does nothing. The cases here used to prove a token never reached the log, which was the right
# test while there was a token; keeping them would pin behaviour that has been removed.
#
# These must not touch the network, so git is pointed at a dead loopback proxy: the clone fails
# instantly, locally, and identically on every machine. Without it the first draft of these tests
# really did clone github, and one case passed only because this developer's OS credential helper
# silently authenticated.
SECRET="ghp_TESTTOKENdonotuse1234567890"
GITHUB_URL="https://github.com/umbraco/umbraco-ai-ops"
nonet() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.proxy GIT_CONFIG_VALUE_0=http://127.0.0.1:1 "$@"; }

H4="$TMP/h4"
nonet env OPS_SRC="$TMP/nope" OPS_REPO="$GITHUB_URL" OPS_HOME="$H4" bash "$SYNC" >/dev/null 2>&1
check "a failed clone still exits 0" 0 $?
if grep -q "network or URL, not auth" "$H4/skill-sync.log"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: the clone hint should say it is not an auth problem"; fi
if grep -qi "token\|private" "$H4/skill-sync.log"; then
  fail=$((fail+1)); echo "FAIL: the log must not send anyone looking for a token"
else pass=$((pass+1)); fi

# A stale token left over from the private-repo era must be inert, and must never be echoed by a
# script that no longer has any reason to read it.
H5="$TMP/h5"
nonet env OPS_SRC="$TMP/nope" OPS_REPO="$GITHUB_URL" OPS_HOME="$H5" \
  OPS_TOKEN="$SECRET" GH_TOKEN="$SECRET" GITHUB_TOKEN="$SECRET" bash "$SYNC" >/dev/null 2>&1
check "a stale token run still exits 0" 0 $?
if grep -q "$SECRET" "$H5/skill-sync.log"; then
  fail=$((fail+1)); echo "FAIL: A STALE TOKEN LEAKED INTO THE LOG"
else pass=$((pass+1)); fi

# And no credential handling has come back into the code. Code lines only: the header
# legitimately explains that it was removed.
if grep -v '^[[:space:]]*#\|^[[:space:]]*$' "$SYNC" \
     | grep -q 'x-access-token\|OPS_TOKEN\|GH_TOKEN\|GITHUB_TOKEN'; then
  fail=$((fail+1)); echo "FAIL: token handling is back in the code"
else pass=$((pass+1)); fi

# VERSION labels the run log; it is NOT a cache key. Asserted because the header used to say the
# opposite, and someone acting on that would bump it and wonder why nothing refreshed.
if grep -q '^VERSION=' "$SYNC"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: VERSION should still exist, to label the run log"; fi
if grep -q "rebuild" "$SYNC"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: the header should point at the stub's rebuild line instead"; fi

# OPS_REPO still points it at a fork.
H6="$TMP/h6"
OPS_SRC="$TMP/nope" OPS_REPO="file:///nonexistent-$$" OPS_HOME="$H6" \
  bash "$SYNC" >/dev/null 2>&1
if grep -q "nonexistent-$$" "$H6/skill-sync.log"; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: OPS_REPO should appear in the failure message"; fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
