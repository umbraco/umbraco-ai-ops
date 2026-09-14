#!/usr/bin/env bash
# Scaffold a capability-skill stub from its catalog entry.
#
# Conformance clause 8(c) — "the installer scaffolds a standard capability-skill stub for each
# missing capability from its catalog entry". Generated rather than hand-written, so a stub can
# never disagree with the catalog about which actions exist: the action names ARE the invocation
# contract, and a stub listing the wrong ones teaches the author the wrong interface.
#
# Every stub carries, without the author having to know to add them:
#   * the do-not-select-me guard          in the description, NOT the disable-model-invocation
#                                         flag: that flag blocks the Skill tool outright, so a
#                                         loop could not call the capability either (proven in
#                                         a live routine, 29-07-2026). See CLAUDE.md.
#   * the reject-unknown-action rule      an unimplemented action must never silently succeed
#   * absent context means {}             not an error
#   * the idempotency requirement         per action, since that is the easiest MUST to miss
#   * the catalog's worked example        as the shape to expect
#
# Usage:
#   scaffold-capability.sh <capability> <dest-dir>   # writes <dest-dir>/ops-<cap>/SKILL.md
#   scaffold-capability.sh <capability> --stdout
#
# Env: CATALOG_FILE overrides the resolved catalog. Never overwrites an existing SKILL.md.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$here/engine-root.sh"
catalog="${CATALOG_FILE:-$(ops_engine_root "$here")/catalog.json}"

# Pull the flag out and keep the rest as an ARRAY. Joining into a string and re-splitting on
# whitespace looked equivalent and was not: a destination under a path with a space in it
# (`C:/Users/Some One/repo`) split into two arguments and the scaffold landed somewhere else, or
# nowhere. Common enough on Windows to be worth the array.
from_default=false
args=()
for a in "$@"; do
  case "$a" in
    --from-default) from_default=true ;;
    *) args+=("$a") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

cap="${1:-}"
dest="${2:-}"
[ -n "$cap" ] && [ -n "$dest" ] || {
  echo "usage: $(basename "$0") <capability> <dest-dir>|--stdout [--from-default]" >&2; exit 2; }

engine_root="$(ops_engine_root "$here")"

# Emit the framework default with a header saying what it is and what to do with it. Without
# that header a copy is indistinguishable from a hand-written override, and the next person
# cannot tell which parts were deliberate.
copy_default() {
  cat <<HDR
<!--
  STARTED AS A COPY of the framework default for ops-$cap.

  You are overriding, so change only what differs for this repo and leave the rest — the
  default already gets the contract right: two positional arguments, an absent context is {},
  unknown actions are rejected, every action idempotent.

  Do NOT add, rename or remove an action. Those names come from the engine's catalog and are
  the invocation contract. Delete this comment once you have made your changes.
-->
HDR
  cat "$1"
}

# Accept the SKILL name as well as the catalog key. The catalog keys capabilities bare
# (`change`) but every other surface a human sees — the coverage report, the scaffolded
# folder, the invocation — uses the prefixed skill name (`ops-change`). Rejecting the
# name the previous command just printed is a papercut, not a contract (28-07-2026).
cap="${cap#ops-}"
[ -f "$catalog" ] || { echo "ERROR: no catalog at $catalog" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 2; }

entry="$(jq -c --arg c "$cap" '.capabilities[] | select(.capability == $c)' "$catalog" 2>/dev/null | tr -d '\r')"
[ -n "$entry" ] || { echo "ERROR: '$cap' is not a capability in the catalog. A repo MUST NOT ship a capability skill the catalog does not declare." >&2; exit 2; }

render() {
  printf '%s' "$entry" | jq -r '
    def esc: gsub("\n"; " ");
    "---",
    "name: ops-\(.capability)",
    "description: >-",
    "  TODO: describe what this does IN THIS REPO. The generic purpose is: \(.description | esc)",
    "  Called by name with (action, context-json). NOT for direct use — never select it from a description match.",
    "---",
    "",
    "# ops-\(.capability)",
    "",
    "> **This is a scaffold.** Every `TODO` below is yours to fill in. The *actions* and their",
    "> names are not — they come from the engine'"'"'s `catalog.json` and are the invocation",
    "> contract. Do not add, rename or remove one.",
    "",
    "\(.description)",
    "",
    "**Visibility: \(.visibility).** " + (
      if .visibility == "service" then "A framework loop may command it."
      elif .visibility == "supporting" then "Only a service calls it — never a loop directly."
      else "Callable from any layer." end),
    (if .kind == "data" then
      "\n**Kind: data.** The structure it returns *is* the deliverable, so every action MUST return well-formed structured data rather than prose."
     else "" end),
    "",
    "## Invocation",
    "",
    "```",
    "ops-\(.capability) <action> '"'"'<context-json>'"'"'",
    "```",
    "",
    "Two positional arguments. `context` is a single JSON object encoded as a string; an",
    "**absent context is `{}`**, not an error. **Reject any action not listed below** — never",
    "guess at one, and never silently succeed.",
    "",
    "| Action | What it must do |",
    "|---|---|",
    (.operations[] | "| `\(.action)` | \(.description | esc) |"),
    "",
    (.operations[] |
      "## Action: `\(.action)`\n" +
      "\n\(.description)\n" +
      "\n**Context it receives** (guidance — never validate it at runtime):\n" +
      "\n```json\n\(.example)\n```\n" +
      (if .input then "\n" + (.input | to_entries | map("- `\(.key)` — \(.value)") | join("\n")) + "\n" else "" end) +
      (if .output then "\n**Facts to return:**\n\n" + (.output | to_entries | map("- `\(.key)` — \(.value)") | join("\n")) + "\n" else "" end) +
      "\n**TODO:** write the steps. Keep them here and nowhere else — this file is the one place\nthis behaviour is described for this repo.\n" +
      "\n**Idempotency (a MUST).** Calling `\(.action)` twice with the same context must not\nproduce a second side effect. TODO: say how this action detects that it has already run.\n"
    ),
    "## Rules",
    "",
    "- **Reject an unknown action.** Report it; never guess, never silently succeed.",
    "- **Every action is idempotent.** A loop sweeps on a cadence and will hand you the same",
    "  work twice.",
    "- **A failed action leaves a safe state** — no partial publish, no dangling branch it",
    "  created and cannot resume.",
    "- **Make success and failure unambiguous.** End with a single JSON object:",
    "  `{\"ok\": true, ...facts...}` or `{\"ok\": false, \"detail\": \"...\"}`.",
    "- **All GitHub work goes through `github-ops`** by operation name — never a raw `gh` or",
    "  `curl` here.",
    "- TODO: add the rules that are specific to this repo."
  '
}

# --from-default: start an OVERRIDE from a copy of the framework default rather than a blank
# stub. Overriding is usually a one-action change — a workspace that also seeds a database, a
# branching model that handles a major cutover — so handing the author six TODOs makes them
# re-derive behaviour the engine already has right. A copy is a diff; a stub is a rewrite.
# Only meaningful where a default exists; for ops-change / ops-release there is nothing to copy.
if [ "$from_default" = true ]; then
  src=""
  search_root="$engine_root/plugins"; [ -d "$search_root" ] || search_root="$engine_root"
  src="$(find "$search_root" -type f -path "*/skills/ops-$cap/SKILL.md" 2>/dev/null | head -1)"
  [ -n "$src" ] || {
    echo "ERROR: no framework default for 'ops-$cap' to copy — scaffold it without --from-default." >&2
    exit 2; }
  if [ "$dest" = "--stdout" ]; then copy_default "$src"; exit 0; fi
  out="$dest/ops-$cap"
  if [ -f "$out/SKILL.md" ]; then
    echo "SKIP: $out/SKILL.md already exists — not overwriting" >&2
    exit 0
  fi
  mkdir -p "$out" || { echo "ERROR: cannot create $out" >&2; exit 2; }
  copy_default "$src" > "$out/SKILL.md" || { echo "ERROR: failed to write $out/SKILL.md" >&2; exit 2; }
  echo "Wrote $out/SKILL.md (copied from the framework default — edit what differs)"
  exit 0
fi

if [ "$dest" = "--stdout" ]; then render; exit 0; fi

out="$dest/ops-$cap"
if [ -f "$out/SKILL.md" ]; then
  echo "SKIP: $out/SKILL.md already exists — not overwriting" >&2
  exit 0
fi
mkdir -p "$out" || { echo "ERROR: cannot create $out" >&2; exit 2; }
render > "$out/SKILL.md" || { echo "ERROR: failed to write $out/SKILL.md" >&2; exit 2; }
echo "Wrote $out/SKILL.md"
