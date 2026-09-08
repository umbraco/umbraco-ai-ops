#!/usr/bin/env bash
# Shared detection primitives for select-profile.sh and inspect.sh. Sourced, never run.
#
# It lives on its own because both scripts have to agree exactly on what a glob means. When they
# had a copy each, a profile could match under `select-profile.sh` and its checks then fail to
# match under `inspect.sh` for the same repo — a disagreement that produces a plausible report
# rather than an error, which is the failure mode this engine is most careful about.
#
# GLOB SEMANTICS, and they are not bash's defaults: a pattern is matched against the WHOLE
# repo-relative path, with `*` crossing `/`. So `*.sln` finds a solution at any depth, and
# `scripts/build*` is anchored at the repo root. There is no `**` and none is needed.

# Directories that are never interesting and are always enormous. Pruned rather than filtered so
# a mature repo stays fast — `.git` alone is most of the entries in one.
PREFLIGHT_PRUNE=(.git node_modules bin obj .vs dist artifacts TestResults packages)

preflight_scan() { # preflight_scan <repo-root> — fills PREFLIGHT_ENTRIES
  local repo="$1" args=() d
  for d in "${PREFLIGHT_PRUNE[@]}"; do args+=(-name "$d" -prune -o); done
  mapfile -t PREFLIGHT_ENTRIES < <(cd "$repo" && find . "${args[@]}" -print 2>/dev/null | sed 's|^\./||')
}

preflight_paths_matching() { # preflight_paths_matching <glob> — prints every entry it matches
  local g="$1" e
  for e in "${PREFLIGHT_ENTRIES[@]}"; do
    # shellcheck disable=SC2053 — $g is a glob on purpose
    [[ $e == $g ]] && printf '%s\n' "$e"
  done
  return 0
}

preflight_match_any_path() { # preflight_match_any_path <glob>... — true if any glob matches
  local g
  for g in "$@"; do
    [ -n "$(preflight_paths_matching "$g")" ] && return 0
  done
  return 1
}

preflight_detect() { # preflight_detect <repo-root> <detect-json> — prints evidence, 0 if any
  local repo="$1" d="$2" found=1 g e pat row
  [ -n "$d" ] && [ "$d" != "null" ] || return 1

  while IFS= read -r g; do
    [ -n "$g" ] || continue
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      printf '%s\n' "$e"; found=0
    done < <(preflight_paths_matching "$g")
    # `tr -d '\r'`: jq on Windows writes CRLF, and a glob carrying a stray CR matches nothing —
    # which reads as "this repo does not have it" rather than as an error. Every jq -r read in
    # this engine strips it for the same reason.
  done < <(printf '%s' "$d" | jq -r '(.any_path // [])[]' 2>/dev/null | tr -d '\r')

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    g="${row%%$'\t'*}"; pat="${row#*$'\t'}"
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      [ -f "$repo/$e" ] || continue
      if grep -qE "$pat" "$repo/$e" 2>/dev/null; then printf '%s\n' "$e"; found=0; fi
    done < <(preflight_paths_matching "$g")
  done < <(printf '%s' "$d" | jq -r '(.any_file_contains // [])[] | "\(.glob)\t\(.pattern)"' 2>/dev/null | tr -d '\r')

  return $found
}
