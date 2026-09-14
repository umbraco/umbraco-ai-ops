#!/usr/bin/env bash
# Tests for list-skills.sh. Hermetic: bash + jq only, nothing filed, no network.
#
# THE RULE THIS FILE GUARDS: a skill description is a CLAIM, never a verdict. The output has to
# carry enough to ask a better question (the name, the description, the path) and nothing that
# could be mistaken for an answer. A live repo shipped a `repo-setup` skill describing dependency
# installation and still answered "no, a bare worktree is not enough" when a human was asked, so
# anything here that resolved a check off a description would be a false pass by construction.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/list-skills.sh"
[ -f "$S" ] || { echo "FATAL: list-skills.sh not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }

pass=0 fail=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 — want [$2] got [$3]"; fi; }

skill() {                                        # <repo> <name> <SKILL.md body>
  local d="$TMP/$1/.claude/skills/$2"; mkdir -p "$d"; printf '%s\n' "$3" > "$d/SKILL.md"
}
agent() {                                        # <repo> <name> <body>
  local d="$TMP/$1/.claude/agents"; mkdir -p "$d"; printf '%s\n' "$3" > "$d/$2.md"
}
j() { bash "$S" "$TMP/$1" --json 2>/dev/null; }
t() { bash "$S" "$TMP/$1" 2>/dev/null; }

# --- a repo that documents nothing --------------------------------------------
mkdir -p "$TMP/bare"
check "an empty repo lists no skills" 0     "$(j bare | jq '.skills | length')"
check "  and no agents"               0     "$(j bare | jq '.agents | length')"
check "  and still exits 0"           0     "$(bash "$S" "$TMP/bare" >/dev/null 2>&1; echo $?)"
check "  and says so in plain words"  1     "$(t bare | grep -c 'Nothing found')"

# --- the ordinary case: a single-line description ------------------------------
skill one repo-setup '---
name: repo-setup
description: Performs initial repository setup including git hooks and dependency installation.
allowed-tools: Bash, Read
---

# Setup'
check "a skill is found by name" "repo-setup" "$(j one | jq -r '.skills[0].name')"
check "  with its description"   "Performs initial repository setup including git hooks and dependency installation." \
  "$(j one | jq -r '.skills[0].description')"
check "  and a repo-relative path" ".claude/skills/repo-setup/SKILL.md" "$(j one | jq -r '.skills[0].path')"
check "  and is not marked as ours" "false" "$(j one | jq -r '.skills[0].engine')"
# `allowed-tools` sits directly after `description`, so a greedy read would swallow it.
check "  a later frontmatter key is not swallowed into the description" 0 \
  "$(j one | jq -r '.skills[0].description' | grep -c 'allowed-tools')"

# --- a folded description, which is just as common ------------------------------
skill fold demo-site '---
name: demo-site
description: >-
  Manages the demo site for development. Handles starting it,
  port discovery, and stopping.
---

# Demo'
check "a folded description is read"  "Manages the demo site for development. Handles starting it, port discovery, and stopping." \
  "$(j fold | jq -r '.skills[0].description')"
check "  and collapses to one line"   1 "$(j fold | jq -r '.skills[0].description' | wc -l)"

# --- a skill with no name, and one with no frontmatter at all -------------------
skill noname orphan-skill '---
description: Does a thing.
---'
check "a skill with no name falls back to its directory" "orphan-skill" "$(j noname | jq -r '.skills[0].name')"
check "  and keeps its description"   "Does a thing." "$(j noname | jq -r '.skills[0].description')"

skill nofm plain-skill '# Just a heading, no frontmatter'
check "a skill with no frontmatter is still listed" "plain-skill" "$(j nofm | jq -r '.skills[0].name')"
check "  with an empty description, not a guess"    ""            "$(j nofm | jq -r '.skills[0].description')"

# --- engine skills mean the repo is part-onboarded ------------------------------
skill mixed ops-change '---
name: ops-change
description: This repo way of building a change.
---'
skill mixed release-management '---
name: release-management
description: Prepares a release.
---'
check "an ops- skill is marked as ours"       "true"  "$(j mixed | jq -r '.skills[] | select(.name=="ops-change") | .engine')"
check "  and a repo skill is not"             "false" "$(j mixed | jq -r '.skills[] | select(.name=="release-management") | .engine')"
check "  and the count is reported"           1       "$(j mixed | jq '.engine_skill_count')"
check "text mode says the repo is part-onboarded" 1   "$(t mixed | grep -c 'already part-onboarded')"
check "  and names which engine skill it found" 1     "$(t mixed | grep -c 'ops-change')"

# --- agents are listed too -------------------------------------------------------
agent withagent release-reviewer '---
name: release-reviewer
description: Reviews a release PR before publishing.
---'
check "an agent is found"        "release-reviewer" "$(j withagent | jq -r '.agents[0].name')"
check "  with its description"   "Reviews a release PR before publishing." "$(j withagent | jq -r '.agents[0].description')"
check "  and agents are separate from skills" 0 "$(j withagent | jq '.skills | length')"

# --- the whole point: it never answers, it only tells you where to ask -----------
out="$(t mixed)"
check "text mode never uses a verdict word" 0 \
  "$(printf '%s' "$out" | grep -ciE 'present|\bgap\b|verdict|pass|fail')"
check "text mode says outright that a description is not proof" 1 \
  "$(printf '%s' "$out" | tr '\n' ' ' | grep -c 'not that it works')"
check "  no em dash anywhere in the output" 0 "$(printf '%s' "$out" | grep -c $'\xe2\x80\x94')"
check "the JSON carries no verdict field"   0 "$(j mixed | grep -c '"verdict"')"

# --- --for: the questions this repo has already answered itself -------------------
# Every check records the capability it is about, in `consumer`. A repo that ships a skill of that
# name has already written the answer down, so the join needs no mapping table.
#
# Watched failing on a live repo: asked what single command builds the product, the answer was "no
# single command", while that repo's own `ops-change` named all three. Asked whether a bare
# worktree is enough, the answer was "it needs a demo site first", while its own `ops-workspace`
# says the opposite and gives its reasoning. Listing skill NAMES did not help, because neither
# answer is in a description.
FIND="$(printf '%s' '{"repo":"/x","sources":[],"findings":[
  {"id":"verify-build-command","consumer":"ops-change","action":"verify","severity":"blocking",
   "section":"Harness","title":"t","why":"w","ask":"What builds it?","verdict":"unknown","evidence":[]},
  {"id":"workspace-isolated-build","consumer":"ops-workspace","action":"prepare","severity":"blocking",
   "section":"Environment","title":"t","why":"w","ask":"Is a worktree enough?","verdict":"unknown","evidence":[]},
  {"id":"general-tool-exposure","consumer":"general","severity":"quality","section":"Misc",
   "title":"t","why":"w","ask":"Which tools?","verdict":"unknown","evidence":[]},
  {"id":"no-question","consumer":"ops-change","action":"verify","severity":"quality","section":"Misc",
   "title":"t","why":"w","verdict":"unknown","evidence":[]},
  {"id":"not-shipped","consumer":"ops-release","action":"cut","severity":"blocking",
   "section":"Release management","title":"t","why":"w","ask":"q?","verdict":"unknown","evidence":[]}
]}' > "$TMP/findings.json"; printf '%s' "$TMP/findings.json")"

skill joined ops-change '---
name: ops-change
description: builds it
---
Run `dotnet build Product.slnx` then `npm run build`.'
skill joined ops-workspace '---
name: ops-workspace
description: a place to build
---
A plain worktree is full CI parity.'

j2() { bash "$S" "$TMP/joined" --for "$FIND" --json 2>/dev/null; }
check "a check whose capability the repo ships is linked" ".claude/skills/ops-change/SKILL.md" \
  "$(j2 | jq -r '.[] | select(.check=="verify-build-command") | .read')"
check "  and says which action to read about" "ops-change · verify" \
  "$(j2 | jq -r '.[] | select(.check=="verify-build-command") | .capability')"
check "a second capability links to its own skill" ".claude/skills/ops-workspace/SKILL.md" \
  "$(j2 | jq -r '.[] | select(.check=="workspace-isolated-build") | .read')"
check "a check owned by no capability is never linked" 0 \
  "$(j2 | jq '[.[] | select(.check=="general-tool-exposure")] | length')"
check "a check with no question is never linked" 0 \
  "$(j2 | jq '[.[] | select(.check=="no-question")] | length')"
check "a capability the repo does NOT ship is not linked" 0 \
  "$(j2 | jq '[.[] | select(.check=="not-shipped")] | length')"
check "only the real links are returned" 2 "$(j2 | jq 'length')"

out="$(bash "$S" "$TMP/joined" --for "$FIND" 2>/dev/null)"
check "text mode says to read before asking" 1 "$(printf '%s' "$out" | grep -c 'Read the file before asking')"
check "  and that it is still a claim" 1 "$(printf '%s' "$out" | tr '\n' ' ' | grep -c 'still a claim, not proof')"

# A repo that has not started onboarding is the normal case, and must not read as a problem.
check "a repo with no capability skills links nothing" 0 \
  "$(bash "$S" "$TMP/one" --for "$FIND" --json 2>/dev/null | jq 'length')"
check "  and says so plainly" 1 \
  "$(bash "$S" "$TMP/one" --for "$FIND" 2>/dev/null | grep -c 'normal case before onboarding')"

# --- --draft: a first pass at who already does what -------------------------------
# Onboarding asks a repo to write `ops-change` and `ops-release`. Most repos have done some of that
# work under their own names. This prints the two lists a person needs to draft the table: the
# actions still to write, and the skills already there.
#
# IT IS DELIBERATELY NOT A MAPPING FILE. A map holds one skill against one action, and every real
# case checked was a skill doing PART of one. On one repo `umb-bump-version` is the version bump
# inside `cut` and none of the branch, changelog or PR; `umb-review` is the review inside `verify`
# and runs no build and no tests. `verify: umb-review` would claim a build that skill has never
# done. So the script prints the lists and the coverage column is written by a person.
d2() { bash "$S" "$TMP/$1" --draft "$FIND" --json 2>/dev/null; }

check "an action the repo has not written is listed" 1 \
  "$(d2 one | jq '[.actions_to_write[] | select(. == "ops-change · verify")] | length')"
check "  and so is the workspace one"                1 \
  "$(d2 one | jq '[.actions_to_write[] | select(. == "ops-workspace · prepare")] | length')"
check "a check owned by no capability is not an action" 0 \
  "$(d2 one | jq '[.actions_to_write[] | select(startswith("ops-") | not)] | length')"
check "the repo's own skills come with it"           "repo-setup" \
  "$(d2 one | jq -r '.skills_it_already_has[0].name')"
check "  with the description, which is what it is judged on" 1 \
  "$(d2 one | jq '[.skills_it_already_has[] | select(.description | test("git hooks"))] | length')"

# A capability the repo already ships is not something it still has to write.
check "a capability already shipped drops off the list" 0 \
  "$(d2 mixed | jq '[.actions_to_write[] | select(startswith("ops-change"))] | length')"
check "  while one it has not written stays"          1 \
  "$(d2 mixed | jq '[.actions_to_write[] | select(. == "ops-workspace · prepare")] | length')"
check "an ops- skill is never offered as a thing to build on" 0 \
  "$(d2 mixed | jq '[.skills_it_already_has[] | select(.name | startswith("ops-"))] | length')"

out="$(bash "$S" "$TMP/one" --draft "$FIND" 2>/dev/null)"
check "text mode asks for a coverage column"  1 "$(printf '%s' "$out" | tr '\n' ' ' | grep -c 'HOW MUCH of the action it covers')"
check "  and says part is the usual answer"   1 "$(printf '%s' "$out" | tr '\n' ' ' | grep -c '"part" is the usual answer')"
check "  and that nothing reads it"           1 "$(printf '%s' "$out" | tr '\n' ' ' | grep -c 'Nothing reads it')"
check "  no em dash"                          0 "$(printf '%s' "$out" | grep -c $'\xe2\x80\x94')"

# Nothing to draft is a real state, not an error: the repo has written them all.
skill full ops-change '---
name: ops-change
description: x
---'
skill full ops-workspace '---
name: ops-workspace
description: x
---'
skill full ops-release '---
name: ops-release
description: x
---'
check "a repo that ships them all has nothing to draft" 0 "$(d2 full | jq '.actions_to_write | length')"
check "  and says so rather than erroring"              1 \
  "$(bash "$S" "$TMP/full" --draft "$FIND" 2>/dev/null | grep -c 'Nothing to draft')"

bash "$S" "$TMP/one" --draft "$TMP/nope.json" >/dev/null 2>&1
check "a missing findings file exits 2" 2 $?

# --- failure modes ---------------------------------------------------------------
bash "$S" >/dev/null 2>&1;                      check "no argument exits 2" 2 $?
bash "$S" "$TMP/does-not-exist" >/dev/null 2>&1; check "a missing directory exits 2" 2 $?
bash "$S" "$TMP/joined" --for "$TMP/nope.json" >/dev/null 2>&1
check "a missing findings file exits 2" 2 $?
printf '%s' '{"hello":true}' > "$TMP/notreport.json"
bash "$S" "$TMP/joined" --for "$TMP/notreport.json" >/dev/null 2>&1
check "a file that is not an inspect report exits 2" 2 $?

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
