#!/usr/bin/env bash
# validate-repo-skills.sh — run the engine's capability-skill frontmatter rules against a
# CONSUMER repo, from wherever the installer happens to be running.
#
# WHY A WRAPPER AND NOT A COPY. The rules live in the engine's scripts/validate-capability-skills.sh
# and are enforced on this repo in CI. A second copy here would drift, and the whole point is that
# a consumer is held to the same rule as the engine. So this resolves the engine root the way every
# other script in this folder does and hands over.
#
# WHY THE INSTALLER NEEDS IT AT ALL. coverage.sh answers "does the repo ship ops-<cap>?" by
# matching NAMES. It never opens the file. So a repo whose ops-change sets
# disable-model-invocation reports `present` — full coverage for a capability no loop can call.
# Umbraco.Automate ran that way with three flagged skills (30-07-2026); the loops fell back to
# reading the files as prose, the PRs looked right, and only close-issue said out loud that it
# could not run. This is the check that would have caught it on the second `/ops-install`.
#
# A GATE THAT CANNOT RUN REPORTS BLOCKED. If the engine copy is not reachable — an installer
# running from a cache with no marketplace clone beside it — this exits 2 saying so. It never
# reports a pass it did not perform, and it never quietly downgrades to a weaker check.
#
# Usage: validate-repo-skills.sh <repo-root>
# Env:   ENGINE_ROOT overrides the resolved engine.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/engine-root.sh"

repo="${1:-}"
[ -n "$repo" ] || { echo "usage: $(basename "$0") <repo-root>" >&2; exit 2; }
[ -d "$repo" ] || { echo "ERROR: no such directory: $repo" >&2; exit 2; }

engine="$(ops_engine_root "$here")"
validator="$engine/scripts/validate-capability-skills.sh"

if [ ! -f "$validator" ]; then
  echo "BLOCKED: cannot check this repo's capability skills." >&2
  echo "  Expected the engine's validator at: $validator" >&2
  echo "  Resolved engine root: $engine" >&2
  echo "  Set ENGINE_ROOT to a umbraco-ai-ops checkout, or run" >&2
  echo "  \`/plugin marketplace update umbraco-ai-ops\` so the clone exists, then re-run." >&2
  echo "  This is BLOCKED, not a pass — the frontmatter rule is unchecked either way." >&2
  exit 2
fi

exec bash "$validator" "$repo"
