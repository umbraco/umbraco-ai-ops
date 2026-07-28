#!/usr/bin/env bash
# engine-root.sh — resolve the engine root. SOURCED by the other scripts here, not executed.
#
# Why this exists: the engine runs from two very different layouts, and no fixed depth works
# for both.
#
#   git checkout      <engine>/plugins/ops-install/skills/ops-install/scripts/
#                     catalog.json is 5 levels up. Every plugin is a sibling under plugins/.
#
#   installed plugin  ~/.claude/plugins/cache/<marketplace>/ops-install/<version>/skills/...
#                     catalog.json is NOWHERE above it. A plugin cache holds only that
#                     plugin's own .claude-plugin/ and skills/ — repo-root files like
#                     catalog.json are not packaged, and the sibling plugins live in
#                     separate cache directories.
#
# So walking up alone is not enough; from a plugin cache it finds nothing. What DOES exist is
# the marketplace clone at ~/.claude/plugins/marketplaces/<marketplace>/, a full checkout of
# this repo — catalog.json, plugins/ and all. It is reachable by walking up to
# ~/.claude/plugins and stepping sideways into marketplaces/.
#
# Hence: at each level going up, check `$d/catalog.json`, then `$d/marketplaces/*/catalog.json`.
# The first is the checkout, the second is the install. Verified against a real install
# (28-07-2026) — an earlier fix here checked only the first and still failed from a cache.
#
# Sourced by path from the caller's own directory, which is safe in both layouts because all
# these scripts move together.
#
# Usage:
#   . "$here/engine-root.sh"
#   engine="$(ops_engine_root "$here")"

# Walk up from $1 looking for the engine root. Prints the directory, or fails.
# The `prev` guard terminates on Windows too, where dirname bottoms out at `D:/`, not `/`.
ops_find_engine() {
  local d="$1" prev="" m
  while [ -n "$d" ] && [ "$d" != "$prev" ]; do
    [ -f "$d/catalog.json" ] && { printf '%s' "$d"; return 0; }
    # Sideways into a marketplace clone. Require plugins/ too, so a marketplace that merely
    # happens to carry a catalog.json cannot be mistaken for this engine.
    for m in "$d"/marketplaces/*/; do
      [ -f "$m/catalog.json" ] && [ -d "$m/plugins" ] && { printf '%s' "${m%/}"; return 0; }
    done
    prev="$d"; d="$(dirname "$d")"
  done
  return 1
}

# ENGINE_ROOT wins, then the walk, then the checkout-relative guess as a last resort so the
# caller still produces its own clear "no catalog at ..." error rather than an empty path.
ops_engine_root() {
  printf '%s' "${ENGINE_ROOT:-$(ops_find_engine "$1" || printf '%s' "$1/../../../../..")}"
}
