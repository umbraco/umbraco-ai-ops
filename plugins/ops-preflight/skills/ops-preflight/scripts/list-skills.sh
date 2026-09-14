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

repo="" fmt="text"
while [ $# -gt 0 ]; do
  case "$1" in
    --json) fmt="json"; shift ;;
    -h|--help) echo "usage: $(basename "$0") <repo-root> [--json]"; exit 0 ;;
    *) [ -n "$repo" ] || repo="$1"; shift ;;
  esac
done

[ -n "$repo" ] || { echo "usage: $(basename "$0") <repo-root> [--json]" >&2; exit 2; }
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
