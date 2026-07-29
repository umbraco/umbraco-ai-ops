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
# Usage: bash validate-capability-skills.sh [engine-root]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${1:-$HERE/..}"
[ -d "$ROOT/plugins" ] || { echo "ERROR: no plugins/ under $ROOT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

CATALOG="${CATALOG_FILE:-$ROOT/catalog.json}"
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
  if ! printf '%s\n' "$fm" | grep -qF "$GUARD"; then
    echo "FAIL: $skill is missing the guard \"$GUARD\" in its description." >&2
    rc=1
  fi

  # 3. The frontmatter name must match the directory, since the NAME is the whole binding.
  if ! printf '%s\n' "$fm" | grep -qx "name: $skill"; then
    echo "FAIL: $skill has a frontmatter name that does not match its directory." >&2
    rc=1
  fi
done < <(find "$ROOT/plugins" -type f -path '*/skills/ops-*/SKILL.md' 2>/dev/null | sort)

[ "$checked" -gt 0 ] || { echo "ERROR: found no capability skills to check under $ROOT/plugins" >&2; exit 2; }

if [ "$rc" -eq 0 ]; then
  echo "OK: $checked capability skill(s) — none blocks the Skill tool, all carry the guard."
fi
exit "$rc"
