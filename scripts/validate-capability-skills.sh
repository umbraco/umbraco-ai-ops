#!/usr/bin/env bash
# validate-capability-skills.sh — the frontmatter rules every capability skill must satisfy.
#
# THIS EXISTS BECAUSE OF ONE BUG. Every capability skill used to carry
# `disable-model-invocation: true`, on the belief that it meant "only a loop may call this".
# It does not. It blocks the Skill tool outright, for the model AND for a subagent, so a loop
# could not call a capability either. A live routine proved it on 29-07-2026:
#
#   Skill ops-change cannot be used with Skill tool due to disable-model-invocation
#
# The loop worked around it by reading the SKILL.md off disk and following it as prose — which
# looks like it worked, and quietly isn't invocation at all: no arguments passed, no result
# returned, no unknown-action rejection, because none of those exist without a call boundary.
#
# So the flag is banned on capability skills, and the thing it was there for — stopping a
# capability auto-firing on a description match — is done with a sentence in the description
# instead. A sentence is weaker than a flag. It is also the only option that leaves the
# capability callable, which is the entire point of the engine.
#
# Loops and the installer are out of scope here, and they do not set the flag either. The rule
# used to read "a human invokes those deliberately, so the flag is correct there", which is wrong
# about the main runtime: a routine is fired with a prompt, and a model choosing the loop by its
# description is the thing the flag blocks. So a flagged loop would break in cloud exactly as a
# flagged capability broke in a routine. Nothing in the repo sets it anywhere.
#
# IT ALSO CHECKS A CONSUMER REPO, and that is not a bolt-on. `/ops-install` reports coverage by
# matching skill NAMES, so a repo whose ops-change carries the flag reports `present` — a clean
# bill of health for a capability no loop can call. That is exactly how Umbraco.Automate ran for
# a day with three flagged skills (30-07-2026): the loops read the files as prose, the work
# looked right, and only `close-issue` said out loud that it could not run. Coverage cannot catch
# this because it never opens the file. This can, so the installer runs it.
#
# Two layouts, one set of rules:
#
#   engine     <root>/plugins/*/skills/ops-<cap>/SKILL.md    the framework defaults
#   consumer   <root>/.claude/skills/ops-<cap>/SKILL.md      the skills a repo owns
#
# A root may have either or both. The catalog comes from the target when it has one and from the
# engine otherwise, because a consumer repo has no catalog.json and the capability list is the
# engine's to define.
#
# Usage: bash validate-capability-skills.sh [root]      # engine root, or a consumer repo root
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$HERE/.."
ROOT="${1:-$ENGINE}"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

# Search roots that actually exist. Neither one is an error — the caller pointed at something
# that is neither an engine checkout nor a repo with capability skills.
roots=()
[ -d "$ROOT/plugins" ] && roots+=("$ROOT/plugins")
[ -d "$ROOT/.claude/skills" ] && roots+=("$ROOT/.claude/skills")
if [ "${#roots[@]}" -eq 0 ]; then
  echo "ERROR: $ROOT has neither plugins/ nor .claude/skills/ — nothing to check." >&2
  exit 2
fi

# The target's own catalog if it is an engine checkout, otherwise this engine's. This script
# always ships inside the engine, so $ENGINE is a reliable fallback in both layouts.
CATALOG="${CATALOG_FILE:-}"
[ -n "$CATALOG" ] || { [ -f "$ROOT/catalog.json" ] && CATALOG="$ROOT/catalog.json" || CATALOG="$ENGINE/catalog.json"; }
[ -f "$CATALOG" ] || { echo "ERROR: no catalog at $CATALOG" >&2; exit 2; }

GUARD="NOT for direct use"
rc=0
checked=0

# A capability skill is one named ops-<capability> where <capability> is in the catalog. That
# keeps loops (ops-*-loop) and the installer out of scope without maintaining a second list.
caps="$(jq -r '.capabilities[].capability' "$CATALOG" | tr -d '\r')"

# Every check below is about FRONTMATTER, so read only that: the text between the first two
# `---` lines. Scanning the whole file gets both checks wrong in opposite directions — a skill
# that merely *discusses* the flag in its prose would fail, and a skill with the guard sentence
# somewhere in its body would pass while its description, the thing a model actually matches on,
# never carries it.
frontmatter() { awk 'NR==1 && $0 != "---" { exit } NR>1 && $0 == "---" { exit } NR>1' "$1"; }

while IFS= read -r f; do
  [ -n "$f" ] || continue
  skill="$(basename "$(dirname "$f")")"
  cap="${skill#ops-}"
  printf '%s\n' "$caps" | grep -qx "$cap" || continue
  checked=$((checked+1))
  fm="$(frontmatter "$f")"

  if [ -z "$fm" ]; then
    echo "FAIL: $skill has no frontmatter block — the name and description are the whole binding." >&2
    rc=1
    continue
  fi

  # 1. The flag must be gone. This is the whole reason the script exists.
  if printf '%s\n' "$fm" | grep -q '^disable-model-invocation: *true'; then
    echo "FAIL: $skill sets disable-model-invocation — that blocks the Skill tool, so no loop can call it." >&2
    rc=1
  fi

  # 2. The replacement guard must be present IN THE DESCRIPTION, or nothing discourages a
  #    description match — which is the only thing the guard is for.
  #    Match against a whitespace-flattened copy. Descriptions are YAML folded scalars (`>-`),
  #    so where the author's line break happens to fall is meaningless — the parsed value joins
  #    them with a space. A line-anchored grep fails on a skill that wraps between "direct" and
  #    "use", which is a guard that is present, correct, and reported missing.
  if ! printf '%s\n' "$fm" | tr '\n' ' ' | tr -s ' ' | grep -qF "$GUARD"; then
    echo "FAIL: $skill is missing the guard \"$GUARD\" in its description." >&2
    rc=1
  fi

  # 3. The frontmatter name must match the directory, since the NAME is the whole binding.
  if ! printf '%s\n' "$fm" | grep -qx "name: $skill"; then
    echo "FAIL: $skill has a frontmatter name that does not match its directory." >&2
    rc=1
  fi
done < <(find "${roots[@]}" -type f -path '*/ops-*/SKILL.md' 2>/dev/null | sort)

# An engine tree with no capability skills is broken — the framework defaults are the point, and
# a validator that passes when it checked nothing is the failure mode this repo keeps hitting.
# A CONSUMER with none is normal: it inherits every default and owns no skill yet. Same silence,
# two different meanings, so say which one it was.
if [ "$checked" -eq 0 ]; then
  if [ -d "$ROOT/plugins" ]; then
    echo "ERROR: found no capability skills to check under $ROOT/plugins" >&2
    exit 2
  fi
  echo "OK: no repo-owned capability skills in $ROOT/.claude/skills — every capability is inherited."
  exit 0
fi

if [ "$rc" -eq 0 ]; then
  echo "OK: $checked capability skill(s) — none blocks the Skill tool, all carry the guard."
fi
exit "$rc"
