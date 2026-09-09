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
# a mature repo stays fast — `.git` alone is most of the entries in one, and a throwaway checkout
# under `.claude/worktrees` (the engine's own `ops-workspace` default creates one per change) would
# otherwise answer every check about ITS OWN copy of the repo rather than the one being inspected —
# found in a real run, where evidence paths pointed straight into `.claude/worktrees/*`.
#
# Data, not a literal buried in one `find` call, so a consumer can extend it without editing this
# file — the same env-override convention `select-profile.sh` uses for `OPS_PREFLIGHT_CHECKS` and
# `OPS_PREFLIGHT_PROFILES`. `OPS_PREFLIGHT_PRUNE` replaces the list wholesale; there is no merge,
# because a prune list has no per-repo layering need the way checks and profiles do.
#
# This does NOT exclude `.claude` wholesale — `.claude/skills/*` is legitimate evidence several
# checks depend on (release-prepare, release-cleanup, general-pattern-mining). Only the scratch
# subtree under it is pruned.
DETECT_LIB_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFLIGHT_PRUNE_FILE="${OPS_PREFLIGHT_PRUNE:-$DETECT_LIB_HERE/prune.json}"

preflight_load_prune() { # fills PREFLIGHT_PRUNE once; safe to call more than once
  [ -n "${PREFLIGHT_PRUNE_LOADED:-}" ] && return 0
  PREFLIGHT_PRUNE_LOADED=1
  if [ -f "$PREFLIGHT_PRUNE_FILE" ] && command -v jq >/dev/null 2>&1; then
    mapfile -t PREFLIGHT_PRUNE < <(jq -r '(.prune // [])[]' "$PREFLIGHT_PRUNE_FILE" 2>/dev/null | tr -d '\r')
  fi
  # A missing or unreadable file falls back to the same minimum this list has always named, so a
  # broken override degrades rather than scanning a whole node_modules into every check.
  if [ "${#PREFLIGHT_PRUNE[@]}" -eq 0 ]; then
    PREFLIGHT_PRUNE=(.git .claude/worktrees .worktrees node_modules bin obj dist out packages TestResults .vs .idea artifacts)
  fi
}

preflight_scan() { # preflight_scan <repo-root> — fills PREFLIGHT_ENTRIES
  local repo="$1" args=() d
  preflight_load_prune
  for d in "${PREFLIGHT_PRUNE[@]}"; do
    if [[ $d == */* ]]; then
      # A compound entry (`.claude/worktrees`) names an exact path from the repo root. `-name`
      # matches a bare basename anywhere, which would prune too much or too little for a path with
      # a `/` in it, so this branch anchors it with `-path` instead.
      args+=(-path "./$d" -prune -o)
    else
      args+=(-name "$d" -prune -o)
    fi
  done
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
  # Thin wrapper over preflight_detect_ex for a caller that only cares whether ANYTHING matched
  # (select-profile.sh's `when`, which has no notion of a check's `signal` and never needs one) —
  # same contract as before this file learned about strength: one path per line, 0 if any matched.
  local out
  out="$(preflight_detect_ex "$1" "$2")" || true
  [ -z "$out" ] && return 1
  printf '%s\n' "$out" | cut -f3-
  return 0
}

preflight_detect_ex() { # preflight_detect_ex <repo-root> <detect-json>: prints "<strength>\t<origin>\t<path>", 0 if any
  # Same matching as preflight_detect used to do alone, plus which STRENGTH each match came in at,
  # so a caller that cares (inspect.sh) can tell a match that names the job from a match that only
  # hints at it. Each `any_path` entry is either a bare glob string (STRONG by default) or an
  # object `{"glob": ..., "strength": "weak"|"strong"}` — inspect.sh resolves a `signal: true`
  # check's bare strings down to `weak` BEFORE calling here, so by the time a detect block reaches
  # this function every entry's effective strength is either explicit or a bare string genuinely
  # meant as `strong`. `any_file_contains` entries carry their own optional `strength` the same way.
  #
  # ORIGIN is which stack profile contributed the pattern (a stack's own name, e.g. "dotnet" or
  # "node"), or "base" for a pattern with no stack tag (the engine base, a repo override, or a
  # single-active-stack repo where inspect.sh never needed to tag anything). inspect.sh's dual-stack
  # union step is the only place that writes a real stack name onto a pattern's `origin`; every
  # other path leaves it unset and this function defaults it to "base" so a whole-product check can
  # tell "this proves the whole product" (base) from "this only proves ONE stack" (a named origin).
  local repo="$1" d="$2" found=1 g e pat row strength origin
  [ -n "$d" ] && [ "$d" != "null" ] || return 1

  while IFS=$'\t' read -r strength origin g; do
    [ -n "$g" ] || continue
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      printf '%s\t%s\t%s\n' "$strength" "$origin" "$e"; found=0
    done < <(preflight_paths_matching "$g")
    # `tr -d '\r'`: jq on Windows writes CRLF, and a glob carrying a stray CR matches nothing —
    # which reads as "this repo does not have it" rather than as an error. Every jq -r read in
    # this engine strips it for the same reason.
  done < <(printf '%s' "$d" | jq -r '
      (.any_path // [])[]
      | if type=="string" then "strong\tbase\t\(.)" else "\(.strength)\t\(.origin // "base")\t\(.glob)" end
    ' 2>/dev/null | tr -d '\r')

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    strength="${row%%$'\t'*}"; row="${row#*$'\t'}"
    origin="${row%%$'\t'*}"; row="${row#*$'\t'}"
    g="${row%%$'\t'*}"; pat="${row#*$'\t'}"
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      [ -f "$repo/$e" ] || continue
      if grep -qE "$pat" "$repo/$e" 2>/dev/null; then printf '%s\t%s\t%s\n' "$strength" "$origin" "$e"; found=0; fi
    done < <(preflight_paths_matching "$g")
  done < <(printf '%s' "$d" | jq -r '(.any_file_contains // [])[] | "\(.strength // "strong")\t\(.origin // "base")\t\(.glob)\t\(.pattern)"' 2>/dev/null | tr -d '\r')

  return $found
}
