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

# --- failure modes ---------------------------------------------------------------
bash "$S" >/dev/null 2>&1;                      check "no argument exits 2" 2 $?
bash "$S" "$TMP/does-not-exist" >/dev/null 2>&1; check "a missing directory exits 2" 2 $?

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" -eq 0 ]
