#!/usr/bin/env bash
# validate-repo-meta.sh — validate a repo's .claude/ops-repo-meta.json.
#
# A THIN WRAPPER. The real validator lives with the schema it enforces, in the ops-capabilities
# plugin (skills/ops-repo-meta/scripts/), because the data seam and its check belong together.
# But this skill's own instructions say "run scripts/validate-repo-meta.sh", and from an
# INSTALLED ops-install that path did not exist — each plugin is cached in its own directory, so
# a sibling plugin's script is not reachable by a relative path. An operator hit exactly that
# and hand-checked the file instead (29-07-2026).
#
# Two ways to fix it: copy the validator here, or find the real one. Copying would give the
# declared-facts seam two enforcement points that could disagree, which is the failure this
# repo's whole single-source rule exists to prevent. So: find it, and exec it.
#
# Usage: bash validate-repo-meta.sh <repo-root>   (same arguments as the real one)
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/engine-root.sh"
engine="$(ops_engine_root "$here")"

# The checkout nests plugins under plugins/; an installed marketplace clone does too, but be
# tolerant of either by searching for the script by path suffix rather than assuming a prefix.
search_root="$engine/plugins"; [ -d "$search_root" ] || search_root="$engine"
real="$(find "$search_root" -type f -path '*/ops-repo-meta/scripts/validate-repo-meta.sh' 2>/dev/null | head -1)"

if [ -z "$real" ]; then
  echo "ERROR: cannot find the real validate-repo-meta.sh." >&2
  echo "  It ships in the ops-capabilities plugin, alongside the schema it enforces." >&2
  echo "  Install it:  /plugin install ops-capabilities@umbraco-ai-ops" >&2
  echo "  Searched under: $search_root" >&2
  exit 2
fi

exec bash "$real" "$@"
