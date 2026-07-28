#!/usr/bin/env bash
# engine-root.sh — resolve the engine root. SOURCED by the other scripts here, not executed.
#
# Why this exists at all: the engine ships in two layouts and they nest to different depths.
# A git checkout puts a script at <engine>/plugins/ops-install/skills/ops-install/scripts/,
# while an installed plugin drops the plugin directly under the marketplace directory with no
# intervening plugins/. So a hard-coded `../../../../..` is right in one and off by one in the
# other — which is what a real install hit, forcing the operator to set ENGINE_ROOT and
# CATALOG_FILE by hand (28-07-2026).
#
# Walking UP for catalog.json is layout-independent: the catalog sits at the engine root in
# both, and no consumer repo has one to be confused by.
#
# Sourced by path from the caller's own directory, which is safe in every layout because all
# these scripts move together — that is the same rule that lets a script resolve its data file
# relative to itself.
#
# Usage:
#   . "$here/engine-root.sh"
#   engine="$(ops_engine_root "$here")"

# Walk up from $1 looking for catalog.json. Prints the directory, or fails.
# The `prev` guard terminates on Windows too, where dirname bottoms out at `D:/`, not `/`.
ops_find_engine() {
  local d="$1" prev=""
  while [ -n "$d" ] && [ "$d" != "$prev" ]; do
    [ -f "$d/catalog.json" ] && { printf '%s' "$d"; return 0; }
    prev="$d"; d="$(dirname "$d")"
  done
  return 1
}

# ENGINE_ROOT wins, then the walk, then the checkout-relative guess as a last resort so the
# caller still produces its own clear "no catalog at ..." error rather than an empty path.
ops_engine_root() {
  printf '%s' "${ENGINE_ROOT:-$(ops_find_engine "$1" || printf '%s' "$1/../../../../..")}"
}
