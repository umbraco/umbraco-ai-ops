#!/usr/bin/env bash
# List what a repo already documents about itself: its own skills and agents, by name and
# description.
#
# WHY THIS EXISTS: a repo's skill descriptions are a short, purpose-written index of what this
# codebase knows how to do, and they answer preflight questions directly. A live repo had a
# `repo-setup` skill describing "git hooks, demo site creation, and dependency installation" (the
# bare-worktree question), a `session-hook-config` skill naming "dotnet restore fails with 401
# errors" (the private-feed question), and a `demo-site-management` skill (the runnable-instance
# question). The interview asked all three anyway, because nothing read them.
#
# THIS NEVER RESOLVES A CHECK. A description is a claim about what a skill does, not evidence that
# the thing works, and the same live repo proves the difference: it ships `repo-setup` and still
# answered "no, a bare worktree is not enough, it needs a demo site stood up". So this output seeds
# QUESTIONS. It is the first place to look when someone answers "I do not know", and the place to
# find the name to put in front of them. A human still gives the verdict.
#
# It also reports which of those skills are the engine's own (`ops-<capability>` or
# `ops-<noun>-loop`). A repo that already has some is part-onboarded, which changes what preflight
# is telling you and used to go unmentioned.
#
# Hermetic: bash + jq. Reads files, runs nothing.
#
# Usage:
#   list-skills.sh <repo-root> [--json]
set -uo pipefail

repo="" fmt="text" for_findings=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) fmt="json"; shift ;;
    --for)  for_findings="${2:-}"; shift 2 ;;
    -h|--help) echo "usage: $(basename "$0") <repo-root> [--json] [--for <findings.json>]"; exit 0 ;;
    *) [ -n "$repo" ] || repo="$1"; shift ;;
  esac
done

[ -n "$repo" ] || { echo "usage: $(basename "$0") <repo-root> [--json] [--for <findings.json>]" >&2; exit 2; }
[ -d "$repo" ] || { echo "ERROR: no such directory: $repo" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

# --- frontmatter ------------------------------------------------------------------------------
# `name` and `description` only. A description is written either on the key's own line or as a
# folded block (`>-`, `>`, `|`), and both shapes are common in the wild, so both are read: after a
# block marker, keep taking lines until one starts at column 0, which is the next top-level key or
# the closing `---`. Everything is collapsed to a single line, because this is an index, not a doc.
frontmatter_field() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR==1 && $0 !~ /^---[[:space:]]*$/ { exit }            # no frontmatter at all
    NR==1 { infm=1; next }
    infm && /^---[[:space:]]*$/ { exit }
    !infm { exit }
    {
      if (collecting) {
        if ($0 ~ /^[^[:space:]]/) { exit }                 # next top-level key ends the block
        line=$0; sub(/^[[:space:]]+/, "", line)
        if (line != "") out = (out == "" ? line : out " " line)
        next
      }
      if (index($0, key ":") == 1) {
        val = substr($0, length(key) + 2)
        sub(/^[[:space:]]+/, "", val)
        if (val ~ /^[>|][-+]?[[:space:]]*$/) { collecting=1; out=""; next }
        out = val; exit
      }
    }
    END { gsub(/[[:space:]]+/, " ", out); sub(/^ /, "", out); sub(/ $/, "", out); print out }
  ' "$file" 2>/dev/null | tr -d '\r'
}

# An engine-owned name: a capability (`ops-<capability>`) or a framework loop (`ops-<noun>-loop`).
# `ops-install` and `ops-preflight` count too: they are ours, and a repo holding a copy of one is
# worth knowing about.
is_engine_name() { case "$1" in ops-*) return 0 ;; *) return 1 ;; esac; }

collect() {                                     # <dir> <glob-suffix> -> tab rows: name, path, desc
  local dir="$1" suffix="$2" f name desc rel
  [ -d "$repo/$dir" ] || return 0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    rel="${f#"$repo"/}"
    name="$(frontmatter_field "$f" name)"
    desc="$(frontmatter_field "$f" description)"
    # A file with no `name` is not a skill; fall back to its directory (or file) name rather than
    # dropping it, because an unnamed skill is still something the repo documents.
    if [ -z "$name" ]; then
      case "$suffix" in
        */SKILL.md) name="$(basename "$(dirname "$f")")" ;;
        *)          name="$(basename "$f" .md)" ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$name" "$rel" "$desc"
  done < <(find "$repo/$dir" -type f -path "*$suffix" 2>/dev/null | sort)
}

rows="$( { collect ".claude/skills" "/SKILL.md"; } )"
agent_rows="$( { collect ".claude/agents" ".md"; } )"

to_json() {                                     # tab rows on stdin -> a JSON array
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | { name: .[0], path: .[1], description: (.[2] // ""),
        engine: (.[0] | startswith("ops-")) })'
}

skills_json="$(printf '%s\n' "$rows" | to_json)"
agents_json="$(printf '%s\n' "$agent_rows" | to_json)"
engine_n="$(printf '%s' "$skills_json" | jq '[.[] | select(.engine)] | length')"
own_n="$(printf '%s' "$skills_json" | jq '[.[] | select(.engine | not)] | length')"
agents_n="$(printf '%s' "$agents_json" | jq 'length')"

# --- --for: which questions this repo may already have answered itself --------------------------
# A repo that has started onboarding ships its own capability skills, and those skills hold the
# answers to questions this interview is about to ask. `ops-change` says what builds the product;
# `ops-workspace` says what a build needs around it.
#
# That is not a guess. Every check records the capability it is about, in `consumer`, and the
# action within it. So a check whose consumer is `ops-change` is answered by the repo's own
# `ops-change`, if it has one. The link already exists in the data and needs no mapping table.
#
# THE FAILURE THIS FIXES was watched happening. A repo was asked "what single command builds this
# whole product?" and answered "no single command". Its own `ops-change` names all three:
# `dotnet build`, `dotnet test` per product, `npm run build` at the root. It was then asked whether
# a bare worktree is enough and answered "it needs a demo site stood up first". Its own
# `ops-workspace` says the opposite, with reasoning: the integration tests are self-contained, the
# pipeline runs them with no SQL and no container, so a plain worktree is full CI parity, and
# `prepare` MUST NOT stand up a demo site. Both answers came from memory of building by hand.
# Listing the skill NAMES was not enough, because neither answer is in a description.
#
# The description-level rule still holds: this says where to read, never what the answer is.
if [ -n "$for_findings" ]; then
  [ -f "$for_findings" ] || { echo "ERROR: no such file: $for_findings" >&2; exit 2; }
  jq -e '.findings | type == "array"' "$for_findings" >/dev/null 2>&1 \
    || { echo "ERROR: $for_findings is not an inspect.sh report (no findings array)" >&2; exit 2; }

  rows="$(jq -r --argjson skills "$skills_json" '
    ($skills | map({key: .name, value: .path}) | from_entries) as $has
    | .findings[]
    | select((.ask // "") != "")
    | select(.consumer != null) | select($has[.consumer] != null)
    | [ .id, (.consumer + (if .action then " · " + .action else "" end)), $has[.consumer] ]
    | @tsv' "$for_findings")"

  if [ "$fmt" = "json" ]; then
    printf '%s\n' "$rows" | jq -Rsc 'split("\n") | map(select(length>0) | split("\t")
      | {check: .[0], capability: .[1], read: .[2]})'
    exit 0
  fi
  if [ -z "$rows" ]; then
    printf 'No question here is about a capability this repo already implements.\n'
    printf 'That is the normal case before onboarding. Ask them all.\n'
    exit 0
  fi
  printf 'This repo may have already answered these, in its own words\n\n'
  printf '%s\n' "$rows" | awk -F'\t' '{ printf "  %-26s %-26s %s\n", $1, $2, $3 }'
  printf '\nRead the file before asking, find the part about that action, and lead the question\n'
  printf 'with what it says. A skill is still a claim, not proof, so the person still answers.\n'
  exit 0
fi

if [ "$fmt" = "json" ]; then
  jq -nc --arg repo "$repo" --argjson skills "$skills_json" --argjson agents "$agents_json" \
    --argjson engine_count "$engine_n" '
    { repo: $repo, skills: $skills, agents: $agents, engine_skill_count: $engine_count }'
  exit 0
fi

# --- text -------------------------------------------------------------------------------------
printf 'What this repo already documents about itself\n\n'

if [ "$own_n" -eq 0 ] && [ "$engine_n" -eq 0 ] && [ "$agents_n" -eq 0 ]; then
  printf 'Nothing found under .claude/skills or .claude/agents.\n'
  printf 'Every question in the interview will have to be answered from memory.\n'
  exit 0
fi

if [ "$own_n" -gt 0 ]; then
  printf "This repo's own skills (%s). Read these before asking anything they cover:\n" "$own_n"
  printf '%s' "$skills_json" | jq -r '.[] | select(.engine | not)
    | "  \(.name)\n      \(if .description == "" then "(no description)" else .description end)"'
  printf '\n'
fi

if [ "$agents_n" -gt 0 ]; then
  printf 'Agents (%s):\n' "$agents_n"
  printf '%s' "$agents_json" | jq -r '.[]
    | "  \(.name)\n      \(if .description == "" then "(no description)" else .description end)"'
  printf '\n'
fi

if [ "$engine_n" -gt 0 ]; then
  printf 'Engine skills found here (%s): %s\n' "$engine_n" \
    "$(printf '%s' "$skills_json" | jq -r '[.[] | select(.engine) | .name] | join(", ")')"
  printf 'This repo is already part-onboarded, so preflight is checking a repo that has started.\n\n'
fi

printf 'None of this answers a check on its own. A description says what a skill claims to do, not\n'
printf 'that it works, so use it to ask a better question and let a person say how it really is.\n'
